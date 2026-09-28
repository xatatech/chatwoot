import Settings from '../Settings.vue';

describe('M360 inbox settings navigation', () => {
  it('exposes the Configuration tab for an M360 SMS inbox', () => {
    const tabs = Settings.computed.tabs.call({
      inbox: { channel_type: 'Channel::Sms', provider: 'm360' },
      $t: key => key,
      isFeatureEnabledonAccount: () => false,
    });
    expect(tabs.some(tab => tab.key === 'configuration')).toBe(true);
  });
});
