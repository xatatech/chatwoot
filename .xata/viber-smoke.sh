#!/usr/bin/env bash
set -euo pipefail
image=${1:?Usage: viber-smoke.sh image}
suffix="viber-smoke-$$"
cleanup() {
  docker rm -f "$suffix-app" "$suffix-db" "$suffix-redis" >/dev/null 2>&1 || true
  docker network rm "$suffix" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker pull pgvector/pgvector:pg16 >/dev/null
docker pull redis:7-alpine >/dev/null
docker network create --internal "$suffix" >/dev/null
docker run -d --name "$suffix-db" --network "$suffix" --network-alias postgres -e POSTGRES_PASSWORD=synthetic-only -e POSTGRES_DB=viber_test pgvector/pgvector:pg16 >/dev/null
docker run -d --name "$suffix-redis" --network "$suffix" --network-alias redis redis:7-alpine >/dev/null
for attempt in $(seq 1 30); do
  if docker exec "$suffix-db" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
docker run --name "$suffix-app" --network "$suffix" \
  -e RAILS_ENV=production -e SECRET_KEY_BASE=synthetic-secret-key-not-for-production-use \
  -e POSTGRES_HOST=postgres -e POSTGRES_DATABASE=viber_test -e POSTGRES_USERNAME=postgres -e POSTGRES_PASSWORD=synthetic-only \
  -e REDIS_URL=redis://redis:6379 -e FRONTEND_URL=https://example.org -e FORCE_SSL=false \
  -e ACTIVE_STORAGE_SERVICE=local -e RAILS_LOG_TO_STDOUT=true -e LOG_LEVEL=error \
  "$image" sh -c 'bundle exec rails db:schema:load && bundle exec rails runner test/viber/rails_smoke.rb'
