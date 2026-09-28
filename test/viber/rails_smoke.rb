# Synthetic integration checks; only run on the disposable internal Docker network.
raise 'Wrong smoke database' unless ENV['POSTGRES_DATABASE'] == 'viber_test'
require 'action_dispatch/testing/integration'
ActiveJob::Base.queue_adapter = :test

def check(condition, description)
  raise "FAIL: #{description}" unless condition
  puts "PASS: #{description}"
end

# Stub only HTTP transport; requests still go through the real Viber client.
requests = []
mode = :ok
sequence = 9_007_199_254_740_992
http = Object.new
%i[use_ssl= open_timeout= read_timeout= write_timeout= max_retries=].each { |method| http.define_singleton_method(method) { |_| } }
http.define_singleton_method(:start) { |&block| block.call(http) }
http.define_singleton_method(:request) do |request|
  requests << [request.path, JSON.parse(request.body), request['X-Viber-Auth-Token']]
  raise Net::ReadTimeout if mode == :timeout && request.path.end_with?('send_message')

  data = if request.path.end_with?('get_account_info')
           { status: 0, id: request['X-Viber-Auth-Token'] == 'second-token' ? 'other-bot' : 'test-bot', name: 'Example bot', uri: 'examplebot' }
         elsif request.path.end_with?('send_message')
           sequence += 1
           (mode == :rejected || (mode == :partial && JSON.parse(request.body)['type'] == 'file')) ? { status: 6 } : { status: 0, message_token: sequence }
         else
           { status: 0 }
         end
  response = Net::HTTPOK.new('1.1', '200', 'OK')
  response.define_singleton_method(:body) { data.to_json }
  response
end
Net::HTTP.define_singleton_method(:new) { |*| http }

account = Account.create!(name: 'Viber synthetic business')
other_account = Account.create!(name: 'Other Viber business')
user = User.new(name: 'Viber admin', email: "viber-#{SecureRandom.hex(4)}@example.test", password: 'Test-Only-Password-2026!')
user.skip_confirmation!
user.save!
AccountUser.create!(account: account, user: user, role: :administrator)
headers = { 'api_access_token' => user.access_token.token }
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! 'example.org'
path = "/api/v1/accounts/#{account.id}/inboxes"
session.post(path, params: { name: 'Viber support', channel: { type: 'viber', bot_token: 'synthetic-token' } }, headers: headers, as: :json)
check(session.response.status == 200, "native inbox creation (#{session.response.status}: #{session.response.body.first(200)})")
inbox = account.inboxes.find(session.response.parsed_body['id'])
channel = inbox.channel
check(inbox.viber? && channel.bot_id == 'test-bot', 'native Viber channel identity')
check(channel.encrypted_bot_token.exclude?('synthetic-token') && channel.bot_token == 'synthetic-token', 'bot token encrypted and decryptable')
check(!session.response.body.include?('synthetic-token') && !session.response.body.include?('encrypted_bot_token'), 'inbox API hides credentials')
check(channel.webhook_status == 'pending', 'setup is pending until webhook registration succeeds')
check(ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job] == Viber::SetupWebhookJob }, 'webhook registration enqueued after commit')
Viber::SetupWebhookJob.perform_now(channel.id)
check(channel.reload.webhook_status == 'connected', 'webhook registration succeeds')
check(requests.last[1]['url'] == channel.webhook_url && requests.last[1]['url'].exclude?('synthetic-token'), 'webhook uses opaque identifier rather than bot token')
session.patch("#{path}/#{inbox.id}", params: { channel: { bot_token: '', reconnect_webhook: true } }, headers: headers, as: :json)
check(session.response.status == 200 && channel.reload.bot_token == 'synthetic-token', 'reconnect preserves saved token')
session.patch("#{path}/#{inbox.id}", params: { channel: { bot_token: 'second-token' } }, headers: headers, as: :json)
check(session.response.status == 422 && channel.reload.bot_id == 'test-bot', 'cannot replace inbox with a different bot')
session.get("/api/v1/accounts/#{other_account.id}/inboxes", headers: headers)
check(session.response.status.between?(401, 404), 'cross-account access rejected')

payload = { event: 'message', message_token: 9_007_199_254_740_999, sender: { id: 'viber-user==', name: 'Customer' }, message: { type: 'text', text: 'Hello support' } }
body = payload.to_json
signature = OpenSSL::HMAC.hexdigest('SHA256', channel.bot_token, body)
webhook_path = URI(channel.webhook_url).path
session.post(webhook_path, params: body, headers: { 'CONTENT_TYPE' => 'application/json', 'X-Viber-Content-Signature' => 'invalid' })
check(session.response.status == 401, 'forged callback rejected')
session.post(webhook_path, params: body, headers: { 'CONTENT_TYPE' => 'application/json', 'X-Viber-Content-Signature' => signature })
check(session.response.status == 200, 'signed callback accepted')
job = ActiveJob::Base.queue_adapter.enqueued_jobs.reverse.find { |item| item[:job] == Webhooks::ViberEventsJob }
check(job[:args][1]['message_token'] == 9_007_199_254_740_999, 'large Viber token retains exact precision')
2.times { Webhooks::ViberEventsJob.perform_now(channel.id, payload.deep_stringify_keys) }
check(inbox.messages.incoming.count == 1 && inbox.contact_inboxes.count == 1, 'callback retries do not duplicate messages or contacts')
incoming = inbox.messages.incoming.last
check(incoming.content == 'Hello support' && incoming.source_id == '9007199254740999', 'incoming message linked to exact Viber ID')
conversation = incoming.conversation

outgoing = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Hello customer')
SendReplyJob.perform_now(outgoing.id)
check(outgoing.reload.sent? && outgoing.source_id == sequence.to_s, 'native agent reply reaches Viber with exact token')
check(requests.last[1]['receiver'] == 'viber-user==', 'reply addressed to Viber user rather than a phone number')
count = requests.count
SendReplyJob.perform_now(outgoing.id)
check(requests.count == count, 'repeated send job cannot duplicate delivered submission')
note = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing, private: true, content: 'Internal note')
SendReplyJob.perform_now(note.id)
check(requests.count == count, 'private notes never leave Chatwoot')

receipt = { 'event' => 'seen', 'message_token' => outgoing.source_id.to_i, 'user_id' => 'viber-user==' }
Webhooks::ViberEventsJob.perform_now(channel.id, receipt)
check(outgoing.reload.read?, 'seen receipt marks message read')
Webhooks::ViberEventsJob.perform_now(channel.id, receipt.merge('event' => 'delivered'))
check(outgoing.reload.read?, 'late delivered receipt cannot regress read status')

other_channel = Channel::Viber.create!(account: other_account, bot_token: 'second-token')
other_inbox = other_account.inboxes.create!(name: 'Other bot', channel: other_channel)
Webhooks::ViberEventsJob.perform_now(other_channel.id, payload.deep_stringify_keys)
check(other_inbox.messages.incoming.count == 1 && other_inbox.contacts.first.id != inbox.contacts.first.id, 'same Viber IDs stay isolated between accounts')
Webhooks::ViberEventsJob.perform_now(other_channel.id, receipt.merge('event' => 'failed'))
check(outgoing.reload.read?, 'other bot cannot change delivery status')

mode = :rejected
rejected = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Reject me')
SendReplyJob.perform_now(rejected.id)
check(rejected.reload.failed? && rejected.external_error.include?('code 6'), 'Viber rejection is visible to agent')
mode = :timeout
uncertain = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Timeout')
SendReplyJob.perform_now(uncertain.id)
count = requests.count
SendReplyJob.perform_now(uncertain.id)
check(uncertain.reload.failed? && requests.count == count, 'timeout is visible and is not automatically retried')
mode = :ok
crashed = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Interrupted', content_attributes: { viber_send_started: true })
SendReplyJob.perform_now(crashed.id)
check(crashed.reload.failed? && requests.count == count, 'worker interruption cannot silently resend')

interrupted_partial = conversation.messages.create!(account: account, inbox: inbox, sender: user, message_type: :outgoing,
                                                   content: 'Interrupted multipart', source_id: 'already-accepted-part',
                                                   content_attributes: { viber_send_started: true })
SendReplyJob.perform_now(interrupted_partial.id)
check(interrupted_partial.reload.failed? && requests.count == count, 'worker interruption after a partial send is visible without resending')

location = payload.deep_dup.merge(message_token: 123, message: { type: 'location', location: { lat: 14.6, lon: 121.0 } })
Webhooks::ViberEventsJob.perform_now(channel.id, location.deep_stringify_keys)
check(inbox.messages.find_by!(source_id: '123').attachments.first.location?, 'incoming location is displayed natively')
contact = payload.deep_dup.merge(message_token: 124, message: { type: 'contact', contact: { name: 'Jane', phone_number: '+639171234567' } })
Webhooks::ViberEventsJob.perform_now(channel.id, contact.deep_stringify_keys)
check(inbox.messages.find_by!(source_id: '124').attachments.first.contact?, 'incoming contact card is displayed natively')

# Exercise uploads, multi-part receipts, and partial provider rejection.
file = StringIO.new('Synthetic document')
with_file = conversation.messages.build(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Document attached')
with_file.attachments.build(account: account, file_type: :file, file: { io: file, filename: 'example.txt', content_type: 'text/plain' })
with_file.save!
SendReplyJob.perform_now(with_file.id)
tokens = with_file.reload.external_source_ids.fetch('viber').keys
check(tokens.length == 2 && requests.last[1]['type'] == 'file', 'text and attachment both reach Viber')
check(requests.last[1]['file_name'] == 'example.txt' && requests.last[1]['size'] == 18, 'file payload contains original name and size')
Webhooks::ViberEventsJob.perform_now(channel.id, receipt.merge('message_token' => tokens.first.to_i))
check(with_file.reload.sent?, 'one read part does not mark whole multipart message read')
Webhooks::ViberEventsJob.perform_now(channel.id, receipt.merge('message_token' => tokens.last.to_i))
check(with_file.reload.read?, 'all multipart receipts mark message read')
mode = :partial
partial = conversation.messages.build(account: account, inbox: inbox, sender: user, message_type: :outgoing, content: 'Partial delivery')
partial.attachments.build(account: account, file_type: :file, file: { io: StringIO.new('File'), filename: 'example.txt', content_type: 'text/plain' })
partial.save!
SendReplyJob.perform_now(partial.id)
check(partial.reload.failed? && partial.source_id.present?, 'partial send failure retains accepted message token')
count = requests.count
SendReplyJob.perform_now(partial.id)
check(requests.count == count, 'partially sent message is not automatically resent')
mode = :ok

SafeFetch.define_singleton_method(:fetch) do |url, **options, &block|
  raise SafeFetch::UnsafeUrlError if url == 'http://127.0.0.1/private'
  check(options[:max_bytes] == 50.megabytes, 'inbound downloads have a size limit')
  Tempfile.create(['viber-smoke', '.txt']) do |tempfile|
    tempfile.write('Received document')
    tempfile.rewind
    block.call(SafeFetch::Result.new(tempfile: tempfile, filename: 'received.txt', content_type: 'text/plain'))
  end
end
media = payload.deep_dup.merge(message_token: 125, message: { type: 'file', media: 'https://example.org/received.txt', file_name: 'received.txt' })
Webhooks::ViberEventsJob.perform_now(channel.id, media.deep_stringify_keys)
check(inbox.messages.find_by!(source_id: '125').attachments.first.file.download == 'Received document', 'inbound media persists before tempfile closes')
unsafe = payload.deep_dup.merge(message_token: 126, message: { type: 'file', media: 'http://127.0.0.1/private' })
Webhooks::ViberEventsJob.perform_now(channel.id, unsafe.deep_stringify_keys)
check(inbox.messages.find_by!(source_id: '126').content.include?('could not be downloaded'), 'blocked media is reported in the conversation')

session.post(path, params: { name: 'Duplicate bot', channel: { type: 'viber', bot_token: 'synthetic-token' } }, headers: headers, as: :json)
check(session.response.status == 422, 'same bot cannot be connected to two inboxes')
session.post(path, params: { name: 'Invalid token', channel: { type: 'viber', bot_token: ['bad'] } }, headers: headers, as: :json)
check(session.response.status == 422, 'malformed token is rejected at validation')
automatic = conversation.messages.create!(account: account, inbox: inbox, message_type: :template, content: 'Automatic greeting')
SendReplyJob.perform_now(automatic.id)
Webhooks::ViberEventsJob.perform_now(channel.id, receipt.merge('message_token' => automatic.reload.source_id.to_i))
check(automatic.reload.read?, 'automatic template messages receive delivery updates')
puts 'Viber Rails smoke checks complete'
