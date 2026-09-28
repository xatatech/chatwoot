require 'net/http'
require 'json'
require 'securerandom'

# One API v4. Keep transport and input validation independent of Rails.
class Sms::M360Client
  ENDPOINT = URI('https://api.m360.com.ph/v4/sms/send').freeze
  GSM_CHARACTERS = ("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡" \
                    'ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà^{}\\[~]|€').freeze
  class Error < StandardError; end

  def initialize(config)
    @config = config
  end

  def send_text(to, content)
    raise Error, 'M360 application credentials are missing' if %w[app_key app_secret].any? { |key| @config[key].to_s.strip.empty? }
    sender = @config['sender_id'].to_s.strip
    raise Error, 'M360 sender ID must contain 1–11 characters' unless sender.length.between?(1, 11)
    raise Error, 'M360 SMS must contain 1–1530 characters' unless content.is_a?(String) && !content.strip.empty? && content.length <= 1530

    number = self.class.normalize_number(to)
    international = !number.start_with?('63')
    raise Error, 'International SMS is disabled for this inbox' if international && @config['international_enabled'] != true

    # Unicode needs DCS 8; GSM basic/extended alphabet uses DCS 0.
    dcs = content.each_char.all? { |char| GSM_CHARACTERS.include?(char) } ? 0 : 8
    payload = {
      app_key: @config['app_key'], app_secret: @config['app_secret'],
      to: ["+#{number}"], content: { text: content }, from: sender,
      request_id: SecureRandom.uuid, is_intl: international, dcs: dcs
    }
    request = Net::HTTP::Post.new(ENDPOINT, 'Content-Type' => 'application/json')
    request.body = JSON.generate(payload)
    http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 20
    http.write_timeout = 20 if http.respond_to?(:write_timeout=)
    http.max_retries = 0
    response = http.start { |connection| connection.request(request) }
    parse_response(response, number)
  rescue Error
    raise
  rescue StandardError
    # A timeout may occur after provider acceptance. Never retry automatically or
    # put provider response bodies, recipients or credentials in exception logs.
    raise Error, 'M360 submission outcome is unknown; check M360 reports before resending'
  end

  def self.normalize_number(value)
    number = value.to_s.strip
    number = number.delete_prefix('+')
    number = "63#{number[1..]}" if number.match?(/\A09\d{9}\z/)
    number = "63#{number}" if number.match?(/\A9\d{9}\z/)
    raise Error, 'Use a valid phone number with its country code' unless number.match?(/\A[1-9]\d{6,14}\z/)

    number
  end

  private

  def parse_response(response, number)
    data = JSON.parse(response.body)
    result = data['data'].first if data.is_a?(Hash) && data['data'].is_a?(Array) && data['data'].length == 1
    accepted = response.code.to_i.between?(200, 299) && data.is_a?(Hash) && data['code'].to_s == '200'
    if accepted && result.is_a?(Hash) && result['code'].to_s == '201' && !result['transid'].to_s.empty?
      return result['transid'] if self.class.normalize_number(result['to']) == number
    end

    if response.code.to_i.between?(400, 499)
      raise Error, "M360 rejected the SMS (HTTP #{response.code.to_i}); check M360 reports"
    end

    raise Error, 'M360 submission was not confirmed; check M360 reports before resending'
  end
end
