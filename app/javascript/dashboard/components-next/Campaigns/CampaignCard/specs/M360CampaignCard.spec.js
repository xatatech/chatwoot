import { shallowMount } from '@vue/test-utils';
import { withFullI18n } from 'test-i18n';
import CampaignCard from '../CampaignCard.vue';

vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({ formatMessage: value => value }),
}));

describe('M360 campaign results', () => {
  withFullI18n();
  it.each([
    [{ accepted: 0, rejected: 2, unknown: 0 }, 'Failed'],
    [{ accepted: 1, rejected: 1, unknown: 0 }, 'Completed with errors'],
    [{ accepted: 0, rejected: 0, unknown: 1 }, 'Needs verification'],
    [{ accepted: 2, rejected: 0, unknown: 0 }, 'Submitted to M360'],
    [{ accepted: 0, rejected: 0, unknown: 0 }, 'No eligible recipients'],
  ])('shows submission outcomes without claiming delivery', (counts, label) => {
    const wrapper = shallowMount(CampaignCard, {
      props: {
        inbox: { channel_type: 'Channel::Sms', name: 'M360' },
        status: 'failed',
        smsSubmission: {
          ...counts,
          skipped: 0,
          errors: ['Safe provider error'],
        },
      },
      global: {
        renderStubDefaultSlot: true,
        directives: { 'dompurify-html': () => {} },
      },
    });
    expect(wrapper.text()).toContain(label);
    expect(wrapper.text()).toContain('Safe provider error');
    expect(wrapper.text()).toContain('not confirmed handset delivery');
  });
});
