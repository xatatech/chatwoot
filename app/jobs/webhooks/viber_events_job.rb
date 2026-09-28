class Webhooks::ViberEventsJob < ApplicationJob
  queue_as :default

  def perform(channel_id, payload)
    channel = Channel::Viber.find_by(id: channel_id)
    return unless channel&.inbox

    # Serialize bot callbacks and sends so retries cannot duplicate contacts/messages,
    # and delivery callbacks cannot race the storage of the provider message token.
    channel.with_delivery_lock do
      case payload['event']
      when 'message'
        Viber::IncomingMessageService.new(inbox: channel.inbox, params: payload.with_indifferent_access).perform
      when 'delivered', 'seen', 'failed'
        Viber::DeliveryStatusService.new(inbox: channel.inbox, params: payload).perform
      end
    end
  end
end
