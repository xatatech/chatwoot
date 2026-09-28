# M360 reports provider acceptance, not handset delivery. Keep a small summary
# in the campaign's existing JSON column so failed submissions are visible.
class Sms::M360CampaignService
  pattr_initialize [:campaign!]

  def perform
    summary = { 'accepted' => 0, 'rejected' => 0, 'unknown' => 0, 'skipped' => 0, 'errors' => [] }
    label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    labels = campaign.account.labels.where(id: label_ids).pluck(:title)
    campaign.account.contacts.tagged_with(labels, any: true).find_each do |contact|
      submit(contact, summary)
    end
    failed = summary['accepted'].zero? || summary['rejected'].positive? || summary['unknown'].positive?
    campaign.update!(campaign_status: failed ? :failed : :completed,
                     trigger_rules: campaign.trigger_rules.merge('m360_submission' => summary))
  end

  private

  def submit(contact, summary)
    if contact.phone_number.blank?
      summary['skipped'] += 1
      return
    end

    content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
    campaign.inbox.channel.send_text_message(contact.phone_number, content)
    summary['accepted'] += 1
  rescue Sms::M360Client::UnknownOutcome => e
    record_error(summary, 'unknown', e.message)
  rescue Sms::M360Client::Error => e
    record_error(summary, 'rejected', e.message)
  rescue StandardError
    # Never echo arbitrary exception text, phone numbers or template content.
    record_error(summary, 'unknown', 'Submission outcome is unknown; check M360 reports before resending')
  end

  def record_error(summary, outcome, message)
    summary[outcome] += 1
    summary['errors'] << message if summary['errors'].length < 5 && !summary['errors'].include?(message)
    Rails.logger.error("[M360 Campaign #{campaign.id}] #{message}")
  end
end
