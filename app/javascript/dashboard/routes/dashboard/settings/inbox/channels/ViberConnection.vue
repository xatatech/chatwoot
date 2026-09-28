<script setup>
import { computed, ref } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({ inbox: { type: Object, required: true } });
const store = useStore();
const { t } = useI18n();
const refreshing = ref(false);
const status = computed(() => {
  if (props.inbox.viber_webhook_status === 'connected')
    return t('INBOX_MGMT.VIBER.STATUSES.connected');
  if (props.inbox.viber_webhook_status === 'failed')
    return t('INBOX_MGMT.VIBER.STATUSES.failed');
  return t('INBOX_MGMT.VIBER.STATUSES.pending');
});
const chatLink = computed(() =>
  props.inbox.bot_uri
    ? `viber://pa?chatURI=${encodeURIComponent(props.inbox.bot_uri)}`
    : null
);
async function refresh() {
  refreshing.value = true;
  try {
    await store.dispatch('inboxes/get');
  } catch {
    useAlert(t('INBOX_MGMT.VIBER.ERROR'));
  } finally {
    refreshing.value = false;
  }
}
</script>

<template>
  <div class="flex flex-col gap-3">
    <p role="status">{{ t('INBOX_MGMT.VIBER.STATUS', { status }) }}</p>
    <p
      v-if="inbox.viber_webhook_error"
      role="alert"
      class="text-sm text-n-ruby-9"
    >
      {{ inbox.viber_webhook_error }}
    </p>
    <a v-if="chatLink" :href="chatLink" class="text-n-blue-9">{{
      t('INBOX_MGMT.VIBER.CHAT_LINK')
    }}</a>
    <NextButton
      type="button"
      :is-loading="refreshing"
      :disabled="refreshing"
      :label="t('INBOX_MGMT.VIBER.REFRESH')"
      @click="refresh"
    />
  </div>
</template>
