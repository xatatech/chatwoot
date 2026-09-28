# Run only against the disposable database created by .xata/smoke.sh.
raise 'Wrong smoke database' unless ENV['POSTGRES_DATABASE'] == 'm360_test'
require 'action_dispatch/testing/integration'
ActiveJob::Base.queue_adapter = :test

def check(condition, description)
  raise "FAIL: #{description}" unless condition
  puts "PASS: #{description}"
end

account = Account.create!(name: 'M360 test')
other_account = Account.create!(name: 'Other business')
user = User.new(name: 'Test admin', email: 'm360-admin@example.test', password: 'Test-Only-Password-2026!')
user.skip_confirmation!
user.save!
AccountUser.create!(account: account, user: user, role: :administrator)
headers = { 'api_access_token' => user.access_token.token }
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! 'example.org'
path = "/api/v1/accounts/#{account.id}/inboxes"
payload = { name: 'M360 test', channel: { type: 'sms', provider: 'm360', provider_config: {
  app_key: 'test-key', app_secret: 'test-secret', sender_id: 'XataTech', international_enabled: false
} } }
session.post(path, params: payload, headers: headers, as: :json)
check(session.response.status == 200, "native inbox creation (HTTP #{session.response.status})")
body = session.response.parsed_body
inbox = account.inboxes.find(body['id'])
channel = inbox.channel
check(channel.m360? && inbox.inbox_type == 'Sms', 'native SMS campaign eligibility')
check(body['phone_number'] == 'XataTech', 'sender ID is displayed without internal identifier')
check(body['m360_config']['sender_id'] == 'XataTech', 'admin can read non-secret settings')
check(!session.response.body.include?('test-secret') && !session.response.body.include?('test-key'), 'API does not expose credentials')
check(channel.reload.provider_config.key?('encrypted_credentials') && !channel.provider_config.to_json.include?('test-secret'), 'credentials encrypted in database')
check(inbox.callback_webhook_url.nil?, 'outbound-only inbox has no incoming webhook')

session.patch("#{path}/#{inbox.id}", params: { channel: { provider_config: { sender_id: 'XataNew', international_enabled: true } } }, headers: headers, as: :json)
check(session.response.status == 200 && channel.reload.m360_public_config['sender_id'] == 'XataNew', 'settings update without replacing saved credentials')
check(channel.send(:m360_credentials)['app_secret'] == 'test-secret', 'saved credentials preserved')
session.patch("#{path}/#{inbox.id}", params: { channel: { provider: 'default' } }, headers: headers, as: :json)
check(session.response.status == 422 && channel.reload.m360?, 'provider cannot silently switch on an existing inbox')

same_sender = Channel::Sms.create!(account: other_account, provider: 'm360', provider_config: {
  app_key: 'other-key', app_secret: 'other-secret', sender_id: 'XataNew'
})
check(same_sender.phone_number != channel.phone_number, 'sender ID may be used in separate business accounts')
session.get("/api/v1/accounts/#{other_account.id}/inboxes", headers: headers)
check(session.response.status.between?(401, 404), 'cross-account inbox access denied')

label = account.labels.create!(title: 'm360-test')
contact = account.contacts.create!(name: 'Recipient', phone_number: '+639171234567')
contact.update_labels([label.title])
other = other_account.contacts.create!(name: 'Other recipient', phone_number: '+639171234568')
other.update_labels([label.title])
campaign = account.campaigns.create!(title: 'M360 campaign', message: 'Hello', inbox: inbox,
                                     audience: [{ type: 'Label', id: label.id }])
# Substitute transport only. Exercise campaign selection and the real adapter.
requests = []
http = Object.new
%i[use_ssl= open_timeout= read_timeout= write_timeout= max_retries=].each { |method| http.define_singleton_method(method) { |_| } }
http.define_singleton_method(:start) { |&block| block.call(http) }
http.define_singleton_method(:request) do |request|
  requests << JSON.parse(request.body)
  Struct.new(:code, :body).new('200', { code: 200, data: [{ code: 201, transid: 'synthetic-transaction', to: '09171234567' }] }.to_json)
end
original_new = Net::HTTP.method(:new)
Net::HTTP.define_singleton_method(:new) { |*| http }
begin
  campaign.trigger!
ensure
  Net::HTTP.define_singleton_method(:new, original_new)
end
check(campaign.reload.completed?, 'native scheduled campaign completes')
check(requests.length == 1 && requests.first['to'] == ['+639171234567'], 'campaign sends only to this business label audience')
check(requests.first['from'] == 'XataNew' && requests.first['app_secret'] == 'test-secret', 'campaign uses configured sender and decrypted credentials')
check(!Channel::Sms.new(account: account, provider: 'm360', provider_config: { sender_id: 'Missing' }).valid?, 'missing credentials rejected')
check(Channel::Sms.new(account: account, phone_number: '+15551234567', provider_config: {}).valid?, 'existing Bandwidth setup stays valid')
puts 'M360 Rails smoke checks complete'

failed_campaign = account.campaigns.create!(title: 'Rejected campaign', message: 'Hello', inbox: inbox,
                                          audience: [{ type: 'Label', id: label.id }])
http.define_singleton_method(:request) do |request|
  requests << JSON.parse(request.body)
  Struct.new(:code, :body).new('400', { code: 400, message: 'Bad Request', data: ['The request id must only contain letters and numbers.'] }.to_json)
end
Net::HTTP.define_singleton_method(:new) { |*| http }
begin
  failed_campaign.trigger!
  check(failed_campaign.reload.campaign_status == 'failed', 'rejected campaign is failed, not completed')
  summary = failed_campaign.trigger_rules.fetch('m360_submission')
  check(summary['accepted'] == 0 && summary['rejected'] == 1, 'provider rejection is recorded')
  check(summary['errors'].include?('M360 rejected the SMS (HTTP 400): The request id must only contain letters and numbers.'), 'safe provider reason is retained')
  previous_count = requests.size
  failed_campaign.trigger!
  check(requests.size == previous_count, 'failed campaign never automatically resends')
ensure
  Net::HTTP.define_singleton_method(:new, original_new)
end

# A campaign can contain both accepted and rejected submissions; neither a
# partial failure nor a timeout may be presented as successful completion.
second_contact = account.contacts.create!(name: 'Second recipient', phone_number: '+639171234569')
second_contact.update_labels([label.title])
[
  ['partial', { 'accepted' => 1, 'rejected' => 1, 'unknown' => 0 }],
  ['timeout', { 'accepted' => 0, 'rejected' => 0, 'unknown' => 2 }]
].each do |mode, expected|
  mixed = account.campaigns.create!(title: mode, message: 'Hello', inbox: inbox,
                                    audience: [{ type: 'Label', id: label.id }])
  calls = 0
  http.define_singleton_method(:request) do |request|
    calls += 1
    raise Net::ReadTimeout, 'sensitive text must not be retained' if mode == 'timeout'
    to = JSON.parse(request.body).fetch('to').first
    code = calls == 1 ? 201 : 400
    Struct.new(:code, :body).new('200', { code: 200, data: [{ code: code, transid: 'synthetic', to: to, message: 'Insufficient Credits.' }] }.to_json)
  end
  Net::HTTP.define_singleton_method(:new) { |*| http }
  begin
    mixed.trigger!
  ensure
    Net::HTTP.define_singleton_method(:new, original_new)
  end
  summary = mixed.reload.trigger_rules.fetch('m360_submission')
  check(mixed.failed? && expected.all? { |key, value| summary[key] == value }, "#{mode} is recorded without claiming completion")
  check(calls == 2 && !summary.to_json.include?('sensitive text'), "#{mode} is not retried and contains no raw error")
end

empty = account.campaigns.create!(title: 'Empty audience', message: 'Hello', inbox: inbox, audience: [])
empty.trigger!
check(empty.reload.failed? && empty.trigger_rules['m360_submission']['accepted'].zero?, 'empty audience does not claim a successful campaign')
session.get("/api/v1/accounts/#{account.id}/campaigns", headers: headers, as: :json)
failed_result = session.response.parsed_body.find { |item| item['id'] == failed_campaign.display_id }
check(failed_result['campaign_status'] == 'failed' && failed_result['sms_submission']['rejected'] == 1, 'campaign API exposes the failed submission summary')
puts 'M360 campaign failure checks complete'
