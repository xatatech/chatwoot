<script setup>
import { reactive, ref, watch } from 'vue';
import { useStore } from 'vuex';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({ inbox: { type: Object, default: null } });
const { t } = useI18n();
const store = useStore();
const router = useRouter();
const saving = ref(false);
const form = reactive({
  name: props.inbox?.name || 'M360 SMS',
  senderId: props.inbox?.m360_config?.sender_id || '',
  appKey: '',
  appSecret: '',
  internationalEnabled:
    props.inbox?.m360_config?.international_enabled || false,
});

watch(
  () => props.inbox?.id,
  () => {
    form.name = props.inbox?.name || 'M360 SMS';
    form.senderId = props.inbox?.m360_config?.sender_id || '';
    form.internationalEnabled =
      props.inbox?.m360_config?.international_enabled || false;
    form.appKey = '';
    form.appSecret = '';
  }
);

async function save() {
  saving.value = true;
  const providerConfig = {
    sender_id: form.senderId.trim(),
    international_enabled: form.internationalEnabled,
  };
  if (form.appKey.trim()) providerConfig.app_key = form.appKey.trim();
  if (form.appSecret.trim()) providerConfig.app_secret = form.appSecret.trim();
  try {
    const channel = {
      type: 'sms',
      provider: 'm360',
      provider_config: providerConfig,
    };
    if (props.inbox) {
      await store.dispatch('inboxes/updateInbox', {
        id: props.inbox.id,
        formData: false,
        channel,
      });
      form.appKey = '';
      form.appSecret = '';
      useAlert(t('INBOX_MGMT.M360.SAVED'));
    } else {
      const inbox = await store.dispatch('inboxes/createChannel', {
        name: form.name.trim(),
        channel,
      });
      router.replace({
        name: 'settings_inboxes_add_agents',
        params: { page: 'new', inbox_id: inbox.id },
      });
    }
  } catch {
    useAlert(t('INBOX_MGMT.M360.ERROR'));
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="save">
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.M360.DESCRIPTION') }}
    </p>
    <label v-if="!inbox">
      {{ t('INBOX_MGMT.M360.INBOX_NAME') }}
      <input v-model="form.name" type="text" required />
    </label>
    <label>
      {{ t('INBOX_MGMT.M360.SENDER_ID') }}
      <input v-model="form.senderId" type="text" maxlength="11" required />
    </label>
    <label>
      {{ t('INBOX_MGMT.M360.APP_KEY') }}
      <input
        v-model="form.appKey"
        type="password"
        autocomplete="new-password"
        :required="!inbox"
      />
    </label>
    <label>
      {{ t('INBOX_MGMT.M360.APP_SECRET') }}
      <input
        v-model="form.appSecret"
        type="password"
        autocomplete="new-password"
        :required="!inbox"
      />
    </label>
    <p v-if="inbox" class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.M360.KEEP_CREDENTIALS') }}
    </p>
    <label class="flex items-center gap-2">
      <input v-model="form.internationalEnabled" type="checkbox" />
      {{ t('INBOX_MGMT.M360.INTERNATIONAL') }}
    </label>
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.M360.DELIVERY_NOTE') }}
    </p>
    <NextButton
      type="submit"
      :is-loading="saving"
      :disabled="saving"
      :label="inbox ? t('INBOX_MGMT.M360.SAVE') : t('INBOX_MGMT.M360.CREATE')"
    />
  </form>
</template>
