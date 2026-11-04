#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
MOCK_CLI="$ROOT_DIR/tests/mock-apps2samsung.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
chmod +x "$INSTALLER" "$MOCK_CLI"

LAST_OUTPUT=""
LAST_CODE=0

invoke() {
    set +e
    LAST_OUTPUT="$("$@" 2>&1)"
    LAST_CODE=$?
    set -e
    printf '%s\n' "$LAST_OUTPUT"
}

expect_success() {
    local name="$1"
    shift
    printf '\n--- %s ---\n' "$name"
    invoke "$@"
    ((LAST_CODE == 0)) || { printf 'FAIL: %s exited with %s\n' "$name" "$LAST_CODE" >&2; exit 1; }
}

expect_failure_contains() {
    local name="$1" expected="$2"
    shift 2
    printf '\n--- %s ---\n' "$name"
    invoke "$@"
    ((LAST_CODE != 0)) || { printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2; exit 1; }
    [[ "$LAST_OUTPUT" == *"$expected"* ]] || { printf 'FAIL: expected text not found: %s\n' "$expected" >&2; exit 1; }
}

common=(bash "$INSTALLER" --tv-ip 127.0.0.1 --local-ip 127.0.0.1 --cli-path "$MOCK_CLI")

expect_failure_contains 'invalid IPv4' 'not a valid IPv4' \
    bash "$INSTALLER" --tv-ip 999.1.1.1 --cli-path "$MOCK_CLI"
expect_failure_contains 'invalid variant' '--variant must be Regular or Oblong' \
    "${common[@]}" --variant Legacy
expect_failure_contains 'Host PC IP mismatch' 'Host PC IP is 10.0.0.2' \
    env MOCK_DEVELOPER_IP=10.0.0.2 "${common[@]}" --validate-only

expect_success 'validate only' "${common[@]}" --validate-only
[[ "$LAST_OUTPUT" == *'Validation completed'* ]] || { printf 'FAIL: validation confirmation missing\n' >&2; exit 1; }

expect_success 'already current' "${common[@]}"
[[ "$LAST_OUTPUT" == *'already up to date'* ]] || { printf 'FAIL: up-to-date confirmation missing\n' >&2; exit 1; }

expect_success 'forced install' "${common[@]}" --force --launch
[[ "$LAST_OUTPUT" == *'installed and verified successfully'* ]] || { printf 'FAIL: installation confirmation missing\n' >&2; exit 1; }

expect_failure_contains 'CLI failure' 'simulated tv failure' \
    env MOCK_FAIL_COMMAND=tv "${common[@]}" --validate-only
expect_failure_contains 'application missing after install' 'missing from the refreshed application list' \
    env MOCK_APP_MISSING=1 "${common[@]}" --force

printf '\nAll Linux integration tests passed.\n'
