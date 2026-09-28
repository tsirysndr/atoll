#!/bin/sh
set -eu

release="/app/bin/atoll"

if [ -z "${DATABASE_PATH:-}" ]; then
  echo "DATABASE_PATH is required; it must be a persistent SQLite file." >&2
  exit 1
fi

database_dir=$(dirname "${DATABASE_PATH}")

if [ ! -d "${database_dir}" ] && ! mkdir -p "${database_dir}" 2>/dev/null; then
  echo "DATABASE_PATH directory ${database_dir} does not exist and cannot be created." >&2
  exit 1
fi

# The image runs as uid 65534; chown 65534:65534 a bind-mounted directory.
if [ ! -w "${database_dir}" ]; then
  echo "DATABASE_PATH directory ${database_dir} is not writable by uid $(id -u)." >&2
  exit 1
fi

case "${1:-start}" in
  start | start_iex | daemon | daemon_iex)
    if [ "${ATOLL_SKIP_MIGRATIONS:-false}" != "true" ]; then
      "${release}" eval 'Atoll.Release.migrate()'
    fi
    ;;
esac

exec "${release}" "$@"
