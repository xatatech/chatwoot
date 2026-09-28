class Viber::SetupWebhookJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel::Viber.find_by(id: channel_id)
    return unless channel&.inbox

    channel.with_delivery_lock do
      raise Viber::Client::Error, 'Chatwoot requires a public HTTPS URL for Viber' unless URI(channel.webhook_url).is_a?(URI::HTTPS)

      channel.client.request('set_webhook', url: channel.webhook_url, event_types: %w[delivered seen failed], send_name: true, send_photo: false)
      channel.update!(webhook_status: 'connected', webhook_error: nil)
    rescue Viber::Client::Error => e
      channel.update!(webhook_status: 'failed', webhook_error: e.message)
    end
  end
end
