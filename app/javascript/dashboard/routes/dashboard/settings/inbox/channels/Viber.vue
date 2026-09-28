<script setup>
import { ref, watch } from 'vue';
import { useStore } from 'vuex';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import ViberConnection from './ViberConnection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({ inbox: { type: Object, default: null } });
const store = useStore();
const router = useRouter();
const { t } = useI18n();
const name = ref('Viber');
const botToken = ref('');
const saving = ref(false);
watch(
  () => props.inbox?.id,
  () => {
    botToken.value = '';
  }
);

async function save() {
  saving.value = true;
  const channel = { type: 'viber', reconnect_webhook: true };
  if (botToken.value.trim()) channel.bot_token = botToken.value.trim();
  try {
    if (props.inbox) {
      await store.dispatch('inboxes/updateInbox', {
        id: props.inbox.id,
        formData: false,
        channel,
      });
      useAlert(t('INBOX_MGMT.VIBER.SAVED'));
    } else {
      const inbox = await store.dispatch('inboxes/createChannel', {
        name: name.value.trim(),
        channel,
      });
      router.replace({
        name: 'settings_inboxes_add_agents',
        params: { page: 'new', inbox_id: inbox.id },
      });
    }
    botToken.value = '';
  } catch (error) {
    useAlert(error.message || t('INBOX_MGMT.VIBER.ERROR'));
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <form class="flex flex-col gap-4 p-6 max-w-xl" @submit.prevent="save">
    <h2 class="text-lg font-medium">{{ t('INBOX_MGMT.VIBER.TITLE') }}</h2>
    <p class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.VIBER.DESCRIPTION') }}
    </p>
    <label v-if="!inbox">
      {{ t('INBOX_MGMT.VIBER.INBOX_NAME') }}
      <input v-model="name" type="text" required />
    </label>
    <label>
      {{ t('INBOX_MGMT.VIBER.BOT_TOKEN') }}
      <input
        v-model="botToken"
        type="password"
        autocomplete="new-password"
        :required="!inbox"
      />
    </label>
    <p v-if="inbox" class="text-sm text-n-slate-11">
      {{ t('INBOX_MGMT.VIBER.KEEP_TOKEN') }}
    </p>
    <ViberConnection v-if="inbox" :inbox="inbox" />
    <NextButton
      type="submit"
      :is-loading="saving"
      :disabled="saving"
      :label="inbox ? t('INBOX_MGMT.VIBER.SAVE') : t('INBOX_MGMT.VIBER.CREATE')"
    />
  </form>
</template>
