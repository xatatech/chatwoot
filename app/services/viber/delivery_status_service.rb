class Viber::DeliveryStatusService
  pattr_initialize [:inbox!, :params!]

  def perform
    token = params['message_token'].to_s
    # The native store serializes external_source_ids as JSON text inside jsonb.
    message = inbox.messages.where(message_type: [:outgoing, :template])
                   .where("(external_source_ids #>> '{}')::jsonb -> 'viber' ? :token", token: token).first
    return unless message && message.conversation.contact_inbox.source_id == params['user_id']

    apply_status(message, token)
  end

  private

  def apply_status(message, token)
    states = message.external_source_ids.fetch('viber')
    status = { 'delivered' => 'delivered', 'seen' => 'read', 'failed' => 'failed' }.fetch(params['event'])
    previous = states.fetch(token)
    return if %w[read failed].include?(previous) || previous == status

    states[token] = status
    message.external_source_ids['viber'] = states
    message.status = aggregate_status(states.values) unless message.failed?
    message.external_error = 'Viber reported delivery failure' if status == 'failed'
    message.save!
  end

  def aggregate_status(states)
    return :failed if states.include?('failed')
    return :read if states.all?('read')
    return :delivered if states.all? { |state| %w[delivered read].include?(state) }

    :sent
  end
end
