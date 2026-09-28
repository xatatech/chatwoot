import { shallowMount, flushPromises } from '@vue/test-utils';
import M360Sms from '../M360Sms.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn(), replace: vi.fn() }));
vi.mock('vuex', () => ({ useStore: () => ({ dispatch: mocks.dispatch }) }));
vi.mock('vue-router', () => ({
  useRouter: () => ({ replace: mocks.replace }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

describe('M360 inbox form', () => {
  it('preserves saved credentials when editing sender settings', async () => {
    mocks.dispatch.mockResolvedValue({});
    const wrapper = shallowMount(M360Sms, {
      props: { inbox: { id: 7, m360_config: { sender_id: 'XataTech' } } },
    });
    await wrapper.find('input[type="text"]').setValue('NewSender');
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 7,
      formData: false,
      channel: {
        type: 'sms',
        provider: 'm360',
        provider_config: {
          sender_id: 'NewSender',
          international_enabled: false,
        },
      },
    });
  });

  it('clears unsaved credentials when switching to another inbox', async () => {
    const wrapper = shallowMount(M360Sms, {
      props: { inbox: { id: 7, m360_config: { sender_id: 'First' } } },
    });
    await wrapper.findAll('input[type="password"]')[0].setValue('unsaved-key');
    await wrapper.setProps({
      inbox: { id: 8, m360_config: { sender_id: 'Second' } },
    });
    expect(wrapper.find('input[type="text"]').element.value).toBe('Second');
    expect(wrapper.findAll('input[type="password"]')[0].element.value).toBe('');
  });
});
