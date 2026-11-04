#!/usr/bin/env bash
set -u

command_name="${1:-}"
if [[ "${MOCK_FAIL_COMMAND:-}" == "$command_name" ]]; then
    printf '{"error":"simulated %s failure"}\n' "$command_name"
    exit 1
fi

case "$command_name" in
    tv)
        developer_ip="${MOCK_DEVELOPER_IP:-127.0.0.1}"
        printf '{"ok":true,"tv":{"ready":true,"developerIp":"%s","model":"MOCK-TV"},"tizenVersion":"8.0"}\n' "$developer_ip"
        ;;
    catalog)
        printf '{"apps":[{"name":"Moonfin","files":[{"file":"Moonfin_Tizen_Regular_v1.2.3.wgt","version":"1.2.3"},{"file":"Moonfin_Tizen_Oblong_v1.2.3.wgt","version":"1.2.3"}]}]}\n'
        ;;
    installed)
        if [[ "${MOCK_APP_MISSING:-0}" == 1 ]]; then
            printf '{"apps":[]}\n'
        else
            version="${MOCK_CURRENT_VERSION:-1.2.3}"
            if [[ -n "${MOCK_INSTALLED_MARKER:-}" && -f "$MOCK_INSTALLED_MARKER" ]]; then version='1.2.3'; fi
            app_id="${MOCK_APP_ID:-MoonfinApp.moonfin}"
            catalog_file="${MOCK_CATALOG_FILE:-Moonfin_Tizen_Regular_v1.2.3.wgt}"
            printf '{"apps":[{"appId":"%s","title":"Moonfin","version":"%s","catalogApp":"Moonfin","catalogFile":"%s"}]}\n' "$app_id" "$version" "$catalog_file"
        fi
        ;;
    cert)
        case "${MOCK_CERT_STATE:-usable}" in
          missing) printf '{"ok":true,"tvDuid":"mock-duid","profiles":[{"level":"Public","exists":false,"usable":false,"duids":[]}]}\n' ;;
          expired) printf '{"ok":true,"tvDuid":"mock-duid","profiles":[{"level":"Public","exists":true,"usable":false,"validUntil":"2025-01-01","duids":["mock-duid"]}]}\n' ;;
          *) printf '{"ok":true,"tvDuid":"mock-duid","profiles":[{"level":"Public","exists":true,"usable":true,"validUntil":"2030-01-01","duids":["mock-duid"]}]}\n' ;;
        esac
        ;;
    install)
        if [[ -n "${MOCK_EXPECT_ARGUMENT:-}" && " $* " != *" $MOCK_EXPECT_ARGUMENT "* ]]; then
            printf '{"error":"missing expected argument: %s"}\n' "$MOCK_EXPECT_ARGUMENT"
            exit 1
        fi
        if [[ -n "${MOCK_INSTALL_ERROR:-}" ]]; then
            printf '{"error":"%s"}\n' "$MOCK_INSTALL_ERROR"
            exit 1
        fi
        [[ -z "${MOCK_INSTALLED_MARKER:-}" ]] || : > "$MOCK_INSTALLED_MARKER"
        printf '{"ok":true}\n'
        ;;
    launch)
        printf '{"ok":true}\n'
        ;;
    *)
        printf '{"error":"unexpected command: %s"}\n' "$command_name"
        exit 2
        ;;
esac
