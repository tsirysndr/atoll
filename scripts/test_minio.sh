#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# These credentials are only for this disposable, loopback-bound test server.
container_name="atoll-minio-test-$$-${RANDOM}"
cleanup() { docker stop "$container_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker build --tag atoll-minio-test:2025-09-07 scripts/minio
docker run --rm --detach --name "$container_name" \
  --publish 127.0.0.1::9000 --tmpfs /data:rw,size=1g \
  --env MINIO_ROOT_USER=atoll-test \
  --env MINIO_ROOT_PASSWORD=atoll-minio-test-only \
  atoll-minio-test:2025-09-07 server /data >/dev/null

binding=$(docker port "$container_name" 9000/tcp)
export ATOLL_MINIO_TEST_ENDPOINT="http://${binding}"
ready=false
for attempt in {1..60}; do
  if curl --fail --silent --max-time 1 "${ATOLL_MINIO_TEST_ENDPOINT}/minio/health/ready" >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo 'MinIO did not become ready within 60 seconds.' >&2
  exit 1
fi

# Keep unrelated runtime options from enabling external services during this test.
ATOLL_IDENTITY_REFRESH_ENABLED=false ATOLL_BLOB_STORAGE=postgres \
  mix test --only minio test/atoll/blobs_minio_test.exs
