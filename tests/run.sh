#!/usr/bin/env bash
# e2e tests: real nvim, real lazy.nvim, real aegis, real git repos.
#
#   tests/run.sh              run everything
#   tests/run.sh 03           run one test by prefix
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${AEGIS_TEST_CACHE:-${TMPDIR:-/tmp}/aegis-nvim-test-cache}"
LAZY="${AEGIS_TEST_LAZY:-$CACHE/lazy.nvim}"

if ! command -v aegis >/dev/null 2>&1; then
  echo "aegis binary not on PATH — install aegis-cli first" >&2
  exit 2
fi

if [ ! -d "$LAZY" ]; then
  echo "fetching lazy.nvim into $LAZY"
  mkdir -p "$CACHE"
  git clone --quiet --filter=blob:none https://github.com/folke/lazy.nvim.git "$LAZY" || exit 2
fi

filter="${1:-}"
status=0

for test in "$PLUGIN_ROOT"/tests/[0-9]*.lua; do
  name="$(basename "$test" .lua)"
  [ -n "$filter" ] && [[ "$name" != "$filter"* ]] && continue

  root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-nvim-$name.XXXXXX")"
  echo "── $name"

  env -i \
    PATH="$PATH" HOME="$root/home" TERM="${TERM:-dumb}" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" \
    AEGIS_TEST_ROOT="$root" \
    AEGIS_TEST_PLUGIN="$PLUGIN_ROOT" \
    AEGIS_TEST_LAZY="$LAZY" \
    nvim --headless --clean -u NONE -l "$test"
  rc=$?

  if [ $rc -ne 0 ]; then
    status=1
    echo "   exit $rc"
    echo "   workdir kept: $root"
  else
    rm -rf "$root"
  fi
done

exit $status
