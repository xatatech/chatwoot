module M360SmsChannel
  extend ActiveSupport::Concern

  included do
    before_validation :prepare_m360_config, if: :m360?
    validate :validate_m360_config, if: :m360?
    validate :prevent_sms_provider_change, on: :update
    before_save :encrypt_m360_credentials, if: :m360?
  end

  def m360?
    provider == 'm360'
  end

  def m360_public_config
    provider_config.slice('sender_id', 'international_enabled')
  end

  def send_m360_text(to, content)
    Sms::M360Client.new(m360_credentials.merge(m360_public_config)).send_text(to, content)
  end

  def send_m360_message(to, message)
    raise Sms::M360Client::Error, 'M360 SMS supports text only' if message.attachments.present?

    send_m360_text(to, message.outgoing_content)
  rescue Sms::M360Client::Error => e
    message.update!(status: :failed, external_error: e.message)
    nil
  end

  private

  def prevent_sms_provider_change
    errors.add(:provider, 'cannot be changed; create a new inbox') if will_save_change_to_provider?
  end

  def prepare_m360_config
    previous = provider_config_in_database || {}
    supplied = provider_config || {}
    self.provider_config = previous.merge(supplied.slice('sender_id', 'international_enabled', 'app_key', 'app_secret'))
    # A sender ID can be used by several business accounts. The native unique
    # phone_number column holds an internal identifier, never a made-up MSISDN.
    self.phone_number = new_record? ? "m360:#{SecureRandom.uuid}" : phone_number_in_database
    provider_config['sender_id'] = provider_config['sender_id'].to_s.strip
    provider_config['international_enabled'] = false unless provider_config.key?('international_enabled')
  end

  def validate_m360_config
    config = provider_config
    errors.add(:provider_config, 'sender ID must contain 1–11 characters') unless config['sender_id'].length.between?(1, 11)
    unless [true, false].include?(config['international_enabled'])
      errors.add(:provider_config, 'international sending must be true or false')
    end
    creds = m360_credentials.merge(config.slice('app_key', 'app_secret'))
    %w[app_key app_secret].each do |key|
      errors.add(:provider_config, "#{key} is required") if creds[key].to_s.strip.empty?
    end
  end

  def m360_encryptor
    key = Rails.application.key_generator.generate_key('chatwoot-m360-credentials-v1', 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
  end

  def m360_credentials
    encrypted = provider_config['encrypted_credentials']
    return {} if encrypted.blank?

    JSON.parse(m360_encryptor.decrypt_and_verify(encrypted, purpose: 'm360-sms'))
  end

  def encrypt_m360_credentials
    creds = m360_credentials.merge(provider_config.slice('app_key', 'app_secret'))
    provider_config['encrypted_credentials'] = m360_encryptor.encrypt_and_sign(creds.to_json, purpose: 'm360-sms')
    provider_config.except!('app_key', 'app_secret')
  end
end
