#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# No service is started, no ports are exposed, and test containers have no network.
# Docker pulls this version only when it is not already cached locally.
promtool_image='prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996'
promtool() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --entrypoint /bin/promtool \
    --mount "type=bind,source=$PWD/ops/prometheus,target=/rules,readonly" \
    --workdir /rules "$promtool_image" "$@"
}

promtool check rules alerts.yml
promtool test rules alerts.test.yml

# Validate actual emitted metric families, including classic histogram framing.
# Compile only; the fixture starts telemetry and the collector, never Atoll/Repo.
ATOLL_BLOB_STORAGE=postgres MIX_ENV=test mix compile --warnings-as-errors
ATOLL_BLOB_STORAGE=postgres MIX_ENV=test mix run --no-start --no-compile scripts/metrics_fixture.exs \
  | docker run --rm -i --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges --entrypoint /bin/promtool \
      "$promtool_image" check metrics
