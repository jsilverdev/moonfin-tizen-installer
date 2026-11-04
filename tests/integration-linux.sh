#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
MOCK_CLI="$ROOT_DIR/tests/mock-apps2samsung.sh"
TMP_DIR="$(mktemp -d)"
export MOCK_INSTALLED_MARKER="$TMP_DIR/installed-marker"
export MOONFIN_INSTALLER_STATE_PATH="$TMP_DIR/installer-state.json"
trap 'rm -rf -- "$TMP_DIR"' EXIT
chmod +x "$INSTALLER" "$MOCK_CLI"

LAST_OUTPUT=""
LAST_CODE=0

invoke() {
    rm -f -- "$MOCK_INSTALLED_MARKER"
    rm -f -- "$MOONFIN_INSTALLER_STATE_PATH"
    if [[ -n "${MOCK_PRESET_VARIANT:-}" ]]; then
        printf '{"appId":"MoonfinApp.moonfin","version":"1.2.3","variant":"%s","file":"remembered.wgt"}\n' "$MOCK_PRESET_VARIANT" > "$MOONFIN_INSTALLER_STATE_PATH"
    fi
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

expect_success 'variant change at same version' \
    env MOCK_CATALOG_FILE=Moonfin_Tizen_Regular_v1.2.3.wgt "${common[@]}" --variant Oblong
[[ "$LAST_OUTPUT" == *'Changing Moonfin'* ]] || { printf 'FAIL: variant change was not detected\n' >&2; exit 1; }
MOCK_PRESET_VARIANT=Oblong expect_success 'remembered variant is preserved' "${common[@]}"
[[ "$LAST_OUTPUT" == *'already up to date (Oblong)'* ]] || { printf 'FAIL: remembered variant was not preserved\n' >&2; exit 1; }

expect_failure_contains 'downgrade is blocked' 'Downgrade blocked' \
    env MOCK_CURRENT_VERSION=10.0.0 "${common[@]}"
expect_success 'explicit downgrade' \
    env MOCK_CURRENT_VERSION=10.0.0 "${common[@]}" --allow-downgrade
[[ "$LAST_OUTPUT" == *'by explicit request'* ]] || { printf 'FAIL: explicit downgrade confirmation missing\n' >&2; exit 1; }

expect_failure_contains 'missing update certificate' 'no reusable certificate' \
    env MOCK_CERT_STATE=missing "${common[@]}" --force
expect_failure_contains 'expired update certificate' 'stored certificate is expired' \
    env MOCK_CERT_STATE=expired "${common[@]}" --force
expect_failure_contains 'certificate mismatch diagnosis' 'signed with another certificate' \
    env MOCK_INSTALL_ERROR='Author certificate not match' "${common[@]}" --force

expect_success 'alternate remembered app id' \
    env MOCK_APP_ID=A2S12345.moonfin "${common[@]}"
[[ "$LAST_OUTPUT" == *'already up to date'* ]] || { printf 'FAIL: alternate app ID was not recognized\n' >&2; exit 1; }

expect_success 'headless certificate login option' \
    env MOCK_EXPECT_ARGUMENT=--no-browser "${common[@]}" --force --no-browser
[[ "$LAST_OUTPUT" == *'installed and verified successfully'* ]] || { printf 'FAIL: headless install did not complete\n' >&2; exit 1; }

printf '\nAll Linux integration tests passed.\n'
