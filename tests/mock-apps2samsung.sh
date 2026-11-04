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
            printf '{"apps":[{"appId":"MoonfinApp.moonfin","version":"1.2.3"}]}\n'
        fi
        ;;
    install)
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
