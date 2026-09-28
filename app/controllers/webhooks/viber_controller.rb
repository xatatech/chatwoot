class Webhooks::ViberController < ActionController::API
  def process_payload
    channel = Channel::Viber.find_by(webhook_identifier: params[:identifier])
    return head :not_found unless channel&.inbox

    return head :unauthorized unless valid_signature?(channel)

    payload = JSON.parse(request.raw_post)
    return head :bad_request unless valid_payload?(payload)

    Webhooks::ViberEventsJob.perform_later(channel.id, payload) unless payload['event'] == 'webhook'
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def valid_signature?(channel)
    signature = request.headers['X-Viber-Content-Signature'].to_s
    expected = OpenSSL::HMAC.hexdigest('SHA256', channel.bot_token, request.raw_post)
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  def valid_payload?(payload)
    return false unless payload.is_a?(Hash) && payload['event'].is_a?(String)
    return true unless payload['event'] == 'message'

    valid_sender?(payload['sender']) && payload['message_token'].is_a?(Integer) && payload['message'].is_a?(Hash)
  end

  def valid_sender?(sender)
    sender.is_a?(Hash) && sender['id'].is_a?(String) && sender['id'].present?
  end
end
