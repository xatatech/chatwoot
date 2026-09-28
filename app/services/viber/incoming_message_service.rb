class Viber::IncomingMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if inbox.messages.incoming.exists?(source_id: params[:message_token].to_s)

    contact_inbox = find_contact
    conversation = existing_conversation(contact_inbox) || contact_inbox.conversations.create!(
      account_id: inbox.account_id, inbox: inbox, contact: contact_inbox.contact
    )
    @message = build_message(conversation, contact_inbox.contact)
    attach_content
    @message.save!
  end

  private

  def find_contact
    ContactInboxWithContactBuilder.new(
      source_id: params.dig(:sender, :id), inbox: inbox,
      contact_attributes: { name: params.dig(:sender, :name).presence || 'Viber user' }
    ).perform
  end

  def build_message(conversation, contact)
    conversation.messages.build(
      account_id: inbox.account_id, inbox: inbox, sender: contact,
      message_type: :incoming, source_id: params[:message_token].to_s,
      content: content, content_attributes: { 'viber_message_type' => data[:type] }
    )
  end

  def data
    params[:message]
  end

  def existing_conversation(contact_inbox)
    conversations = contact_inbox.conversations
    conversations = conversations.where.not(status: :resolved) unless inbox.lock_to_single_conversation
    conversations.last
  end

  def content
    return data[:media] if data[:type] == 'url'
    return data[:text] if data[:text].present?
    return if %w[picture video file location contact].include?(data[:type])

    I18n.t('viber.unsupported_message', type: data[:type])
  end

  def attach_content
    case data[:type]
    when 'picture', 'video', 'file', 'sticker'
      attach_file if data[:media].present?
    when 'location'
      @message.attachments.build(account_id: inbox.account_id, file_type: :location,
                                 coordinates_lat: data.dig(:location, :lat), coordinates_long: data.dig(:location, :lon))
    when 'contact'
      @message.attachments.build(account_id: inbox.account_id, file_type: :contact,
                                 fallback_title: data.dig(:contact, :phone_number), meta: { first_name: data.dig(:contact, :name) })
    end
  end

  def attach_file
    type = { 'picture' => :image, 'sticker' => :image, 'video' => :video, 'file' => :file }.fetch(data[:type])
    SafeFetch.fetch(data[:media], max_bytes: 50.megabytes, validate_content_type: false) do |result|
      @message.attachments.build(
        account_id: inbox.account_id, file_type: type,
        file: { io: result.tempfile, filename: data[:file_name].presence || result.filename, content_type: result.content_type }
      )
      # Upload while SafeFetch's temporary file is still open.
      @message.save!
    end
  rescue SafeFetch::Error
    @message.content = [@message.content, I18n.t('viber.attachment_unavailable')].compact.join("\n")
  end
end
