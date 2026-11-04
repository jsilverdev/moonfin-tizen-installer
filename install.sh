#!/usr/bin/env bash
set -Eeuo pipefail

TV_IP=""
LOCAL_IP=""
VARIANT="Regular"
CLI_PATH=""
LAUNCH=0
FORCE=0
VALIDATE_ONLY=0

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="$ROOT_DIR/.tools"
STATE_ROOT="$ROOT_DIR/.state/apps2samsung"
RELEASE_API="https://api.github.com/repos/Apps2Samsung/Apps2Samsung/releases/latest"

usage() {
    cat <<'EOF'
Usage: ./install.sh --tv-ip ADDRESS [options]

Options:
  --local-ip ADDRESS   Local address configured as Host PC IP on the TV.
  --variant NAME       Moonfin variant: Regular (default) or Oblong.
  --cli-path PATH      Use an existing apps2samsung-cli executable.
  --launch             Launch Moonfin after installing or checking it.
  --force              Reinstall even when the same version is installed.
  --validate-only      Validate the TV and catalog without installing.
  -h, --help           Show this help.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

is_ipv4() {
    local address="$1"
    python3 -c 'import ipaddress,sys
try:
    value = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if value.version == 4 else 1)' "$address"
}

while (($#)); do
    case "$1" in
        --tv-ip) (($# >= 2)) || fail '--tv-ip requires a value'; TV_IP="$2"; shift 2 ;;
        --local-ip) (($# >= 2)) || fail '--local-ip requires a value'; LOCAL_IP="$2"; shift 2 ;;
        --variant) (($# >= 2)) || fail '--variant requires a value'; VARIANT="$2"; shift 2 ;;
        --cli-path) (($# >= 2)) || fail '--cli-path requires a value'; CLI_PATH="$2"; shift 2 ;;
        --launch) LAUNCH=1; shift ;;
        --force) FORCE=1; shift ;;
        --validate-only) VALIDATE_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

require_command python3
[[ -n "$TV_IP" ]] || fail '--tv-ip is required.'
is_ipv4 "$TV_IP" || fail "'$TV_IP' is not a valid IPv4 address."
if [[ -n "$LOCAL_IP" ]]; then
    is_ipv4 "$LOCAL_IP" || fail "'$LOCAL_IP' is not a valid IPv4 address."
fi
case "$VARIANT" in
    Regular|Oblong) ;;
    *) fail '--variant must be Regular or Oblong.' ;;
esac

if [[ -z "$LOCAL_IP" ]]; then
    LOCAL_IP="$(python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:
    s.connect((sys.argv[1],26101))
    print(s.getsockname()[0])
finally:
    s.close()' "$TV_IP")"
fi

json_value() {
    local json="$1" expression="$2"
    JSON_INPUT="$json" python3 -c 'import json,os,sys
value=json.loads(os.environ["JSON_INPUT"])
for part in sys.argv[1].split("."):
    if part:
        value=value[part]
if isinstance(value,bool):
    print(str(value).lower())
elif value is not None:
    print(value)' "$expression"
}

get_cli() {
    if [[ -n "$CLI_PATH" ]]; then
        [[ -f "$CLI_PATH" && -x "$CLI_PATH" ]] || fail "Apps2Samsung CLI is not executable: $CLI_PATH"
        printf '%s\n' "$(cd -- "$(dirname -- "$CLI_PATH")" && pwd)/$(basename -- "$CLI_PATH")"
        return
    fi

    require_command curl
    require_command sha256sum
    require_command tar

    local machine platform release_json asset_json asset_name asset_url asset_digest version install_dir archive cli
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) platform='linux-x64' ;;
        aarch64|arm64) platform='linux-arm64' ;;
        *) fail "Unsupported Linux architecture: $machine" ;;
    esac

    printf 'Consulting the latest stable Apps2Samsung release...\n' >&2
    release_json="$(curl --fail --location --silent --show-error \
        --header 'Accept: application/vnd.github+json' \
        --header 'User-Agent: moonfin-tizen-installer' "$RELEASE_API")"
    asset_json="$(RELEASE_JSON="$release_json" python3 -c 'import json,os,re,sys
release=json.loads(os.environ["RELEASE_JSON"])
pattern=re.compile(r"^Apps2Samsung-cli-v.+-"+re.escape(sys.argv[1])+r"\.tar\.gz$")
asset=next((item for item in release.get("assets",[]) if pattern.match(item.get("name",""))),None)
if asset is None:
    raise SystemExit(1)
print(json.dumps({"name":asset["name"],"url":asset["browser_download_url"],"digest":asset.get("digest"),"tag":release["tag_name"]}))' "$platform")" || fail "The stable release does not contain a CLI for $platform."

    asset_name="$(json_value "$asset_json" name)"
    asset_url="$(json_value "$asset_json" url)"
    asset_digest="$(json_value "$asset_json" digest)"
    version="$(json_value "$asset_json" tag)"
    version="${version#v}"
    [[ "$asset_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || fail 'GitHub did not publish a valid SHA-256 digest.'

    install_dir="$TOOLS_ROOT/apps2samsung-$version-$platform"
    cli="$install_dir/apps2samsung-cli"
    if [[ ! -x "$cli" && -d "$install_dir" ]]; then
        cli="$(find "$install_dir" -type f -name apps2samsung-cli -print -quit)"
    fi
    [[ -n "$cli" && -x "$cli" ]] && { printf '%s\n' "$cli"; return; }

    mkdir -p -- "$TOOLS_ROOT" "$install_dir"
    archive="$TOOLS_ROOT/$asset_name"
    printf 'Downloading Apps2Samsung %s for %s...\n' "$version" "$platform" >&2
    curl --fail --location --show-error --output "$archive.part" "$asset_url"
    local actual_digest
    actual_digest="sha256:$(sha256sum "$archive.part" | awk '{print $1}')"
    [[ "${actual_digest,,}" == "${asset_digest,,}" ]] || { rm -f -- "$archive.part"; fail "SHA-256 mismatch. Expected: $asset_digest; got: $actual_digest"; }
    mv -f -- "$archive.part" "$archive"
    tar -xzf "$archive" -C "$install_dir"
    if [[ ! -f "$cli" ]]; then
        cli="$(find "$install_dir" -type f -name apps2samsung-cli -print -quit)"
    fi
    [[ -n "$cli" && -f "$cli" ]] || fail 'The verified archive did not contain apps2samsung-cli.'
    chmod +x "$cli"
    printf '%s\n' "$cli"
}

invoke_json() {
    local output status
    set +e
    output="$($CLI "$@" --json --quiet 2>&1)"
    status=$?
    set -e
    if ((status != 0)); then
        fail "Apps2Samsung failed ($status): $output"
    fi
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$output" || fail "Apps2Samsung returned invalid JSON: $output"
    printf '%s\n' "$output"
}

mkdir -p -- "$STATE_ROOT"
CLI="$(get_cli)"

printf 'Checking TV %s from %s...\n' "$TV_IP" "$LOCAL_IP"
tv_json="$(invoke_json tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
[[ "$(json_value "$tv_json" ok)" == true && "$(json_value "$tv_json" tv.ready)" == true ]] || \
    fail 'The TV is not ready. Enable Developer Mode, set Host PC IP, and fully restart it.'
developer_ip="$(json_value "$tv_json" tv.developerIp)"
[[ "$developer_ip" == "$LOCAL_IP" ]] || fail "The TV Host PC IP is $developer_ip, but this computer uses $LOCAL_IP."
printf 'TV ready: %s, Tizen %s.\n' "$(json_value "$tv_json" tv.model)" "$(json_value "$tv_json" tizenVersion)"

printf 'Looking up Moonfin in the signed catalog...\n'
catalog_json="$(invoke_json catalog Moonfin --data-dir "$STATE_ROOT")"
package_json="$(CATALOG_JSON="$catalog_json" python3 -c 'import json,os,re,sys
catalog=json.loads(os.environ["CATALOG_JSON"])
app=next((item for item in catalog.get("apps",[]) if item.get("name")=="Moonfin"),None)
if app is None:
    raise SystemExit(2)
pattern=re.compile(r"^Moonfin_Tizen_"+re.escape(sys.argv[1])+r"_v.+\.wgt$")
files=[item for item in app.get("files",[]) if pattern.match(item.get("file",""))]
if not files:
    raise SystemExit(3)
files.sort(key=lambda item:item.get("version",""),reverse=True)
print(json.dumps(files[0]))' "$VARIANT")" || fail "Moonfin did not publish the $VARIANT variant in the current catalog."
package_file="$(json_value "$package_json" file)"
package_version="$(json_value "$package_json" version)"

if ((VALIDATE_ONLY)); then
    printf 'Validation completed: TV ready and Moonfin %s (%s) is available.\n' "$package_version" "$VARIANT"
    exit 0
fi

installed_json="$(invoke_json installed --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
current_version="$(INSTALLED_JSON="$installed_json" python3 -c 'import json,os
data=json.loads(os.environ["INSTALLED_JSON"])
app=next((item for item in data.get("apps",[]) if item.get("appId")=="MoonfinApp.moonfin"),None)
print("" if app is None else app.get("version",""))')"

if [[ "$current_version" == "$package_version" ]] && ((FORCE == 0)); then
    printf 'Moonfin %s is already up to date (%s). Use --force to reinstall.\n' "$current_version" "$VARIANT"
    if ((LAUNCH)); then
        invoke_json launch MoonfinApp.moonfin --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT" >/dev/null
        printf 'Moonfin launched on the TV.\n'
    fi
    exit 0
fi

if [[ -n "$current_version" ]]; then
    printf 'Updating Moonfin %s to %s (%s)...\n' "$current_version" "$package_version" "$VARIANT"
else
    printf 'Installing Moonfin %s (%s)...\n' "$package_version" "$VARIANT"
fi

install_args=(install Moonfin --file "$package_file" --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT" --keep --json)
((LAUNCH)) && install_args+=(--launch)
set +e
"$CLI" "${install_args[@]}"
install_status=$?
set -e
((install_status == 0)) || fail "Installation exited with code $install_status. No application was removed."

verified_json="$(invoke_json installed --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
verified_version="$(INSTALLED_JSON="$verified_json" python3 -c 'import json,os
data=json.loads(os.environ["INSTALLED_JSON"])
app=next((item for item in data.get("apps",[]) if item.get("appId")=="MoonfinApp.moonfin"),None)
print("" if app is None else app.get("version",""))')"
[[ -n "$verified_version" ]] || fail 'Apps2Samsung finished, but Moonfin is missing from the refreshed application list.'
[[ "$verified_version" == "$package_version" ]] || fail "Moonfin reports version $verified_version, expected $package_version."
printf 'Moonfin %s (%s) installed and verified successfully.\n' "$verified_version" "$VARIANT"
