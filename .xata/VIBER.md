# Native Viber chatbot channel

This fork adds **Settings → Inboxes → Add inbox → Viber**, using the direct [Viber chatbot API](https://developers.viber.com/docs/api/rest-bot-api/). It runs in Chatwoot web and Sidekiq, with no external bridge. It builds on the existing M360 customization.

## Setup

1. Build and deploy this fork to both Chatwoot web and worker services, applying `20260928000000_create_channel_viber` first under the normal maintenance procedure. `FRONTEND_URL` must be a publicly reachable HTTPS origin with a trusted certificate. Keep `SECRET_KEY_BASE` stable; it is used to encrypt bot tokens.
2. Choose **Add inbox → Viber**, enter a name and your Viber chatbot token, then assign agents. Use one inbox per bot. Saving replaces the bot's existing webhook.
3. Webhook registration runs after the inbox transaction commits. On the final setup page, refresh the connection status until it says **Connected**. Errors appear on the same screen. Use **Inbox settings → Configuration → Save and reconnect** to retry or rotate a token for the same bot; blank token input retains the saved token.
4. Open the chatbot link and send a message from a subscribed Viber user. Reply from Chatwoot. Confirm the reply arrives, then check delivered/read states and test an attachment.

Bot tokens never appear in inbox API responses or webhook URLs. Signed Viber events are verified against the exact raw request body. Customer identity is the Viber user ID scoped to an inbox, not a phone number.

## Supported behavior

- Incoming text, URLs, pictures, videos, file payloads when provided by Viber, stickers with media, contact cards, and locations. Media is downloaded promptly into Chatwoot storage through its bounded, SSRF-protected downloader. Failed downloads produce a visible conversation message.
- Public agent replies with text, pictures, MP4 video, and files. Small JPEG/PNG images (up to 1 MiB) and MP4 video (up to 26 MiB) use native media messages; other uploads use file messages (up to 50 MiB). Instance upload limits still apply. Viber's file-format restrictions remain applicable.
- Text plus attachments is submitted as separate Viber messages. Delivery/read state advances only when all submitted parts reach that state. A partial failure is shown as failed, with accepted provider IDs retained.
- Plain-text rendering and a 7,000-character reply limit. Private notes are never sent.
- Normal Chatwoot contact, conversation, assignment, labels, working-hours, and agent-reply flows. Existing conversations follow the inbox's lock-to-single-conversation setting.
- Callback retries are deduplicated. Large integer message tokens remain exact strings in Chatwoot. A PostgreSQL advisory lock serializes events and sends per bot without rolling back the persisted send-attempt marker on a network failure.
- Timeouts or interrupted sends are not automatically resubmitted: Viber does not document an idempotency key for sends. Inspect the customer's chat before manually creating another reply. Rejected recipients, including unsubscribed users, surface a provider error code to the agent.

This initial channel does not implement broadcasts/campaigns, rich keyboards/carousels, quoted replies, proactive welcome messages on `conversation_started`, or historical chat import. Subscription-only events do not create empty conversations. It does not connect Business Messages partner APIs or personal accounts. If deleting an inbox without moving the bot to another service, remove its webhook through Viber (`set_webhook` with an empty URL); inbox deletion removes local routing only.

## Verification and release

`.xata/viber-smoke.sh <image>` creates disposable PostgreSQL/Redis/application containers on an internal Docker network. The smoke script substitutes HTTP transport and uses synthetic tokens only. It checks native API creation, credential secrecy, webhook authentication, retry deduplication, tenant isolation, public/private replies, rejection/timeouts, media persistence, multipart status, and token validation. It never sends a real Viber message.

`Dockerfile.m360` now includes the custom routes, locale, schema and migration as well as the application code. `.xata/build.sh` runs both M360 and Viber smoke checks before publishing an image; the existing immutable build/release process remains in place. The upstream dependency and migration guard allows only the new Viber migration and updated schema.

This release adds a table. Use the ops migration procedure before starting web and workers. Rolling back the application image can leave the additive table in place, preserving Viber data; avoid rolling back the migration or deleting that table. The old image cannot operate Viber inboxes.

### Validation — 28 September 2026

- Additive migration applied successfully to an isolated database based on the upstream schema.
- 42 Viber integration checks and 28 existing M360 regression checks passed against the packaged application on disposable internal Docker networks.
- 147 existing frontend checks passed for inbox settings, channel composables/mixins and the reply composer. The Docker frontend stage also passed its 17 existing fork checks.
- New Ruby implementation passes the repository-pinned RuboCop rules. Updated JavaScript/Vue passes ESLint (one existing dynamic-translation-key warning in ChannelName); new components pass Prettier.
- Production dashboard/widget and SDK builds passed. Browser verification confirmed the Viber channel card, setup form, inbox listing and Configuration tab, with an empty masked token field and refresh/reconnect controls.
- No production changes, real bot credentials or live messages were used.
