require 'net/http'

class Viber::Client
  class Error < StandardError; end

  API_URL = 'https://chatapi.viber.com/pa/'.freeze

  def initialize(token)
    @token = token
  end

  def request(method, payload = {})
    parse_response(perform_request(method, payload))
  rescue JSON::ParserError
    raise Error, 'Invalid Viber response'
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    raise Error, 'Viber connection failed; delivery may be uncertain. Check before resending.'
  end

  private

  def perform_request(method, payload)
    uri = URI("#{API_URL}#{method}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 20
    http.write_timeout = 20
    http.max_retries = 0
    request = Net::HTTP::Post.new(uri)
    request['X-Viber-Auth-Token'] = @token
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json
    raise Error, 'Viber message exceeds the 30 KB request limit' if request.body.bytesize > 30.kilobytes

    http.start { |connection| connection.request(request) }
  end

  def parse_response(response)
    raise Error, "Viber HTTP error #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    raise Error, 'Invalid Viber response' unless data.is_a?(Hash) && data['status'].is_a?(Integer)
    raise Error, "Viber rejected the request (code #{data['status']})" unless data['status'].zero?

    data
  end
end
