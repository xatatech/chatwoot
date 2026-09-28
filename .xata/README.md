# Native M360 SMS campaigns

This fork starts from upstream Chatwoot v4.18.0. Select **Settings → Inboxes → Add inbox → SMS → M360**. Enter an inbox name, the approved sender ID, application key and application secret. Assign agents, then use **Campaigns → One-off** to choose this inbox, audience labels, message and scheduled time. Administrators can change sender ID, replace credentials, or enable international sending from the inbox Configuration tab. Leaving credential fields blank preserves the saved values. No inbound access code is required.

The adapter uses the [M360 One API v4](https://developer.m360.com.ph/one/api/guides) at `https://api.m360.com.ph/v4/sms/send`, with credentials in the JSON payload. It sends one recipient per request so native campaign personalization continues to work. PH numbers are normalized and international sending is disabled by default. Encoding is selected automatically: GSM alphabet uses DCS 0; other characters use DCS 8. Credentials are encrypted in the existing SMS configuration column with a key derived from Chatwoot's `SECRET_KEY_BASE`. Preserve that secret during upgrades and restore it with database backups.

## Behavior and limits

- Uses the existing native SMS campaign scheduler and audience selection; no custom database migrations.
- SMS is text only. No inbound messages, attachments, or MMS.
- API acceptance is not handset delivery. M360 campaign cards show accepted, rejected, uncertain and skipped counts, plus safe provider errors. Rejections, uncertain outcomes and empty audiences receive a terminal failed status; partial acceptance is displayed as completed with errors. Successful submissions show Submitted to M360. Check M360's dashboard for delivery reports; DLR ingestion and per-recipient campaign reports are not included.
- Request IDs contain only letters and numbers, as required by M360. Hyphenated UUIDs are rejected before SMS submission.
- Failure summaries use the existing trigger_rules JSON column and the failed enum value 3. Rolling back to the original image hides these new statuses; do not reset failed campaigns to active, as that would send them again.
- Network timeouts and unconfirmed responses are not automatically retried, because v4 `request_id` is a correlation identifier, not a documented idempotency guarantee. Check the provider dashboard before resending.
- This is a maintained fork, not a public Chatwoot plugin. No guarantee of conflict-free future upgrades.

## Build and validation

AWS CodeBuild reads `buildspec.m360.yml`. Start it with an exact 40-character source commit. It validates the upstream dependency boundary, runs offline protocol tests, rebuilds the Vue assets, runs isolated PostgreSQL/Redis smoke checks for native inbox creation, encrypted settings, tenant isolation and campaign sending, then pushes an immutable ECR tag. It produces `release.json` containing the source revision and image digest. It has no ECS deployment or runtime-secret permissions.

The custom image reuses the official runtime and gems, verifies its upstream Git SHA and Gemfile.lock, and rebuilds the application assets. `BUILD_BASE_IMAGE` can reference an ECR mirror of the same upstream runtime. `Dockerfile.m360` is separate from upstream's Dockerfile to keep merges small.

Local verification:

```sh
ruby test/m360/client_test.rb
pnpm install --frozen-lockfile --ignore-scripts
pnpm exec eslint app/javascript/dashboard/routes/dashboard/settings/inbox/channels/M360Sms.vue
# Supply the matching upstream image and commit from .xata/upstream.json:
docker build --target runtime -f Dockerfile.m360 --build-arg UPSTREAM_IMAGE=<image> --build-arg UPSTREAM_COMMIT=<commit> --build-arg SOURCE_COMMIT=<fork-commit> -t m360-runtime:test .
bash .xata/smoke.sh m360-runtime:test
```

Tests use synthetic data in disposable containers on an internal Docker network. They never send real SMS or use production credentials.

## Updating from upstream

1. Fetch upstream tags and create an upgrade branch from the fork's production branch. Merge the chosen stable release tag. Do not hard-reset the production branch to upstream or use GitHub's discard-changes synchronization.
2. Resolve conflicts while retaining M360 source files and native integration changes. Update `.xata/upstream.json` to the selected release tag, commit and official image digest. Update the CodeBuild runtime mirror to the same release; otherwise the build fails its Git-SHA check.
3. Run the tests and CodeBuild against the exact upgrade commit. Tests must pass before an image is published. Deploy only a build marked SUCCEEDED with a matching release manifest; a later publication/manifest failure can leave an unpromoted image in ECR. Review the resulting PR and any upstream migration requirements.
4. Promote `release.json`'s image digest through the ops repository to **both** Chatwoot web and worker tasks. Keep the current digest recorded for rollback. Ordinary official-image updates do not contain this extension.
5. For an upstream version change, back up, stop writers/workers, run the upstream database preparation with the new image, and verify before reopening traffic. Database migrations can make reverting only the image unsafe. Follow the ops maintenance runbook.

CodeBuild builds on demand. There is no automatic production rollout or scheduled upstream merge.
