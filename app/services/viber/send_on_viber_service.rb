class Viber::SendOnViberService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Viber
  end

  def outgoing_message_originated_from_channel?
    message.content_attributes['viber_send_complete'] ||
      (message.source_id.present? && !message.content_attributes['viber_send_started'])
  end

  def perform_reply
    channel.with_delivery_lock do
      message.reload
      return if message.content_attributes['viber_send_complete'] || message.failed?

      raise Viber::Client::Error, 'Viber delivery is uncertain. Check before resending.' if message.content_attributes['viber_send_started']

      submit_message
    end
  rescue Viber::Client::Error => e
    message.update!(status: :failed, external_error: e.message)
  end

  def submit_message
    payloads = message_payloads
    # Persist before network I/O: a worker crash must not resend a charged message.
    message.update!(content_attributes: message.content_attributes.merge('viber_send_started' => true))
    payloads.each { |payload| send_payload(payload) }
    message.update!(content_attributes: message.content_attributes.merge('viber_send_complete' => true))
  end

  def message_payloads
    text = message.outgoing_content.to_s
    raise Viber::Client::Error, 'Viber text is limited to 7,000 characters' if text.length > 7000

    payloads = text.present? ? [{ type: 'text', text: text }] : []
    payloads + message.attachments.map { |attachment| attachment_payload(attachment) }
  end

  def attachment_payload(attachment)
    raise Viber::Client::Error, 'This attachment type is not supported by Viber' unless attachment.file.attached?

    blob = attachment.file.blob
    raise Viber::Client::Error, 'Viber files are limited to 50 MB' if blob.byte_size > 50.megabytes

    payload = { media: attachment.download_url, size: blob.byte_size }
    case media_type(blob)
    when 'picture'
      payload.merge(type: 'picture', text: '')
    when 'video'
      payload.merge(type: 'video')
    else
      payload.merge(type: 'file', file_name: blob.filename.to_s)
    end
  end

  def media_type(blob)
    return 'picture' if %w[image/jpeg image/png].include?(blob.content_type) && blob.byte_size <= 1.megabyte
    return 'video' if blob.content_type == 'video/mp4' && blob.byte_size <= 26.megabytes

    'file'
  end

  def send_payload(payload)
    response = channel.client.request('send_message', payload.merge(
                                                        receiver: contact_inbox.source_id, sender: { name: channel.bot_name.first(28) }
                                                      ))
    token = response['message_token']
    raise Viber::Client::Error, 'Viber did not confirm a message ID. Check before resending.' unless token.is_a?(Integer)

    ids = message.external_source_ids || {}
    ids['viber'] = (ids['viber'] || {}).merge(token.to_s => 'sent')
    message.update!(source_id: message.source_id.presence || token.to_s, external_source_ids: ids, status: :sent)
  end
end
