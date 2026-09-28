require 'minitest/autorun'
module Sms; end
require_relative '../../app/services/sms/m360_client'

class M360ClientTest < Minitest::Test
  Response = Struct.new(:code, :body)
  class Transport
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests
    def initialize(response)
      @response = response
      @requests = []
    end
    def start
      yield self
    end
    def request(request)
      @requests << request
      raise @response if @response.is_a?(Exception)
      @response
    end
  end

  def config
    { 'app_key' => 'test-key', 'app_secret' => 'test-secret', 'sender_id' => 'XataTech' }
  end

  def response(to = '09171234567', code = 201)
    Response.new('200', JSON.generate(code: 200, data: [{ code: code, transid: 'm360-id', to: to }]))
  end

  def with_transport(response)
    transport = Transport.new(response)
    Net::HTTP.stub(:new, transport) { yield transport }
  end

  def test_v4_payload_and_acceptance
    with_transport(response) do |http|
      assert_equal 'm360-id', Sms::M360Client.new(config).send_text('+639171234567', 'Hello')
      request = http.requests.fetch(0)
      payload = JSON.parse(request.body)
      assert_equal '/v4/sms/send', request.path
      assert_equal ['+639171234567'], payload['to']
      assert_equal({ 'text' => 'Hello' }, payload['content'])
      assert_equal 'XataTech', payload['from']
      assert_equal 'test-key', payload['app_key']
      assert_equal 'test-secret', payload['app_secret']
      assert_equal 0, payload['dcs']
      assert_equal false, payload['is_intl']
      refute_empty payload['request_id']
      assert_match(/\A[a-zA-Z0-9]+\z/, payload['request_id'], 'M360 rejects special characters in request_id')
      assert_equal true, http.use_ssl
      assert_equal 0, http.max_retries
    end
  end

  def test_unicode_and_international_flag
    with_transport(response('+12077687523')) do |http|
      Sms::M360Client.new(config.merge('international_enabled' => true)).send_text('+12077687523', 'Hello 👋')
      payload = JSON.parse(http.requests.first.body)
      assert_equal 8, payload['dcs']
      assert_equal true, payload['is_intl']
    end
  end

  def test_ph_formats
    %w[09171234567 9171234567 639171234567 +639171234567].each do |number|
      assert_equal '639171234567', Sms::M360Client.normalize_number(number)
    end
  end

  def test_international_e164_length
    assert_equal '123456789012345', Sms::M360Client.normalize_number('+123456789012345')
    assert_raises(Sms::M360Client::Error) { Sms::M360Client.normalize_number('+1234567890123456') }
  end

  def test_validation_does_not_contact_provider
    with_transport(response) do |http|
      ['123', '+63 9171234567', '+12077687523'].each do |to|
        assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text(to, 'Hello') }
      end
      ['', ' '].each do |content|
        assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', content) }
      end
      assert_empty http.requests
    end
  end

  def test_per_recipient_rejection_is_not_success_even_with_http_200
    with_transport(response('09171234567', 400)) do
      assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', 'Hello') }
    end
  end

  def test_wrong_recipient_and_malformed_responses_are_not_success
    [response('09171234568'), Response.new('200', 'invalid json'), Response.new('503', 'unavailable')].each do |result|
      with_transport(result) do
        assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', 'Hello') }
      end
    end
  end

  def test_validation_reason_is_retained_without_raw_response_values
    result = Response.new('400', JSON.generate(code: 400, message: 'Bad Request', data: [
      'The request id must only contain letters and numbers.', 'test-secret test-key +639171234567'
    ]))
    with_transport(result) do
      error = assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', 'Hello') }
      assert_match(/The request id must only contain letters and numbers/, error.message)
      refute_match(/test-secret|test-key|639171234567/, error.message)
    end
  end

  def test_http_rejection_with_non_json_body_stays_a_rejection
    with_transport(Response.new('400', '<html>Bad request</html>')) do
      error = assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', 'Hello') }
      refute_kind_of Sms::M360Client::UnknownOutcome, error
      assert_match(/HTTP 400/, error.message)
    end
  end

  def test_timeout_is_not_retried_and_secrets_are_not_exposed
    with_transport(Net::ReadTimeout.new('test-secret test-key')) do |http|
      error = assert_raises(Sms::M360Client::Error) { Sms::M360Client.new(config).send_text('09171234567', 'Hello') }
      assert_equal 1, http.requests.length
      assert_kind_of Sms::M360Client::UnknownOutcome, error
      assert_match(/unknown/, error.message)
      refute_match(/test-secret|test-key/, error.message)
    end
  end
end
