class Channel::Viber < ApplicationRecord
  include Channelable

  self.table_name = 'channel_viber'
  EDITABLE_ATTRS = [:bot_token, :reconnect_webhook].freeze
  attr_accessor :reconnect_webhook

  before_validation :load_bot, if: :will_save_change_to_encrypted_bot_token?
  before_validation :set_webhook_identifier, on: :create
  validate :validate_bot_token_type
  validates :encrypted_bot_token, :bot_id, :bot_name, :webhook_identifier, presence: true
  validates :bot_id, :webhook_identifier, uniqueness: true
  validates :reconnect_webhook, inclusion: { in: [true, false] }, allow_nil: true
  before_save :mark_webhook_pending, if: :webhook_setup_required?
  after_save_commit :enqueue_webhook_setup, if: :webhook_setup_committed?

  def name
    'Viber'
  end

  def bot_token=(value)
    @invalid_bot_token_type = !value.is_a?(String)
    return if @invalid_bot_token_type || value.blank?

    self.encrypted_bot_token = token_encryptor.encrypt_and_sign(value, purpose: 'viber-bot')
  end

  def bot_token
    return if encrypted_bot_token.blank?

    token_encryptor.decrypt_and_verify(encrypted_bot_token, purpose: 'viber-bot')
  end

  def client
    ::Viber::Client.new(bot_token)
  end

  def webhook_url
    "#{ENV.fetch('FRONTEND_URL').delete_suffix('/')}/webhooks/viber/#{webhook_identifier}"
  end

  # A session lock serializes this bot without wrapping network calls in a DB
  # transaction. Send-attempt markers must survive a worker crash or timeout.
  def with_delivery_lock
    self.class.connection_pool.with_connection do |connection|
      key = connection.quote("viber:#{id}")
      connection.execute("SELECT pg_advisory_lock(hashtextextended(#{key}, 0))")
      begin
        reload
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
      end
    end
  end

  private

  def validate_bot_token_type
    errors.add(:bot_token, 'must be a string') if @invalid_bot_token_type
  end

  def token_encryptor
    key = Rails.application.key_generator.generate_key('chatwoot-viber-credentials-v1', 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
  end

  def set_webhook_identifier
    self.webhook_identifier ||= SecureRandom.uuid
  end

  def load_bot
    return if encrypted_bot_token.blank?

    data = client.request('get_account_info')
    if persisted? && data['id'] != bot_id
      errors.add(:bot_token, 'belongs to a different bot; create a new inbox')
      return
    end
    self.bot_id = data['id']
    self.bot_name = data['name']
    self.bot_uri = data['uri']
  rescue ::Viber::Client::Error => e
    errors.add(:bot_token, e.message)
  end

  def webhook_setup_required?
    will_save_change_to_encrypted_bot_token? || reconnect_webhook == true
  end

  def webhook_setup_committed?
    saved_change_to_encrypted_bot_token? || reconnect_webhook == true
  end

  def mark_webhook_pending
    self.webhook_status = 'pending'
    self.webhook_error = nil
  end

  def enqueue_webhook_setup
    ::Viber::SetupWebhookJob.perform_later(id)
  end
end
