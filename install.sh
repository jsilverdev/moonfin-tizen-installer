#!/usr/bin/env bash
set -Eeuo pipefail

TV_IP=""
LOCAL_IP=""
VARIANT="Regular"
VARIANT_EXPLICIT=0
CLI_PATH=""
LAUNCH=0
FORCE=0
VALIDATE_ONLY=0
ALLOW_DOWNGRADE=0
NO_BROWSER=0
NETWORK_RETRIES=3

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="$ROOT_DIR/.tools"
STATE_ROOT="$ROOT_DIR/.state/apps2samsung"
INSTALLER_STATE_PATH="${MOONFIN_INSTALLER_STATE_PATH:-$STATE_ROOT/moonfin-installer.json}"
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
  --allow-downgrade    Explicitly allow installing an older catalog version.
  --no-browser         Print the Samsung sign-in URL (headless/SSH systems).
  --network-retries N  Network/read retries (default: 3).
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
        --variant) (($# >= 2)) || fail '--variant requires a value'; VARIANT="$2"; VARIANT_EXPLICIT=1; shift 2 ;;
        --cli-path) (($# >= 2)) || fail '--cli-path requires a value'; CLI_PATH="$2"; shift 2 ;;
        --launch) LAUNCH=1; shift ;;
        --force) FORCE=1; shift ;;
        --validate-only) VALIDATE_ONLY=1; shift ;;
        --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
        --no-browser) NO_BROWSER=1; shift ;;
        --network-retries) (($# >= 2)) || fail '--network-retries requires a value'; NETWORK_RETRIES="$2"; shift 2 ;;
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
[[ "$NETWORK_RETRIES" =~ ^[1-9]$|^10$ ]] || fail '--network-retries must be between 1 and 10.'

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

compare_versions() {
    python3 -c 'import re,sys
def parse(value):
    match=re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?",value)
    if not match:
        raise SystemExit(2)
    core=tuple(map(int,match.group(1,2,3)))
    pre=match.group(4)
    parts=[] if pre is None else [int(p) if p.isdigit() else p for p in pre.split(".")]
    return core,pre,parts
left=parse(sys.argv[1]); right=parse(sys.argv[2])
if left[0] != right[0]:
    print(-1 if left[0] < right[0] else 1); raise SystemExit
if left[1] is None or right[1] is None:
    print(0 if left[1] is right[1] else (1 if left[1] is None else -1)); raise SystemExit
for a,b in zip(left[2],right[2]):
    if a == b: continue
    if isinstance(a,int) != isinstance(b,int): print(-1 if isinstance(a,int) else 1)
    else: print(-1 if a < b else 1)
    raise SystemExit
print((len(left[2])>len(right[2]))-(len(left[2])<len(right[2])))' "$1" "$2"
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

    local machine platform release_json asset_json asset_name asset_url asset_digest version install_dir archive cli cached_cli
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) platform='linux-x64' ;;
        aarch64|arm64) platform='linux-arm64' ;;
        *) fail "Unsupported Linux architecture: $machine" ;;
    esac

    printf 'Consulting the latest stable Apps2Samsung release...\n' >&2
    local curl_headers=(--header 'Accept: application/vnd.github+json' --header 'User-Agent: moonfin-tizen-installer')
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
    fi
    if ! release_json="$(curl --fail --location --silent --show-error \
        --retry "$NETWORK_RETRIES" --retry-delay 2 --retry-connrefused --retry-all-errors \
        "${curl_headers[@]}" "$RELEASE_API")"; then
        cached_cli="$(find "$TOOLS_ROOT" -type f -path "*/apps2samsung-*-$platform/apps2samsung-cli" -perm -u+x -print 2>/dev/null | sort -r | head -n 1)"
        if [[ -n "$cached_cli" ]]; then
            printf 'WARNING: GitHub could not be reached; using cached CLI: %s\n' "$cached_cli" >&2
            printf '%s\n' "$cached_cli"
            return
        fi
        fail 'Could not query Apps2Samsung and no cached CLI is available.'
    fi
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
    curl --fail --location --show-error \
        --retry "$NETWORK_RETRIES" --retry-delay 2 --retry-connrefused --retry-all-errors \
        --output "$archive.part" "$asset_url"
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
    local attempts=1
    if [[ "${1:-}" == '--attempts' ]]; then
        attempts="$2"
        shift 2
    fi
    local output status valid attempt delay
    for ((attempt=1; attempt<=attempts; attempt++)); do
        set +e
        output="$($CLI "$@" --json --quiet 2>&1)"
        status=$?
        set -e
        valid=0
        python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$output" >/dev/null 2>&1 && valid=1
        if ((status == 0 && valid == 1)); then
            printf '%s\n' "$output"
            return
        fi
        if ((attempt < attempts)); then
            delay=$((2 ** attempt))
            ((delay > 8)) && delay=8
            printf 'WARNING: Apps2Samsung failed (attempt %s of %s); retrying in %s s.\n' "$attempt" "$attempts" "$delay" >&2
            sleep "$delay"
        fi
    done
    ((status == 0)) || fail "Apps2Samsung failed ($status): $output"
    fail "Apps2Samsung returned invalid JSON: $output"
}

get_certificate_readiness() {
    local certificate_json usable_count existing_count dates
    certificate_json="$(invoke_json --attempts 2 cert --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
    usable_count="$(CERTIFICATE_JSON="$certificate_json" python3 -c 'import json,os
data=json.loads(os.environ["CERTIFICATE_JSON"])
print(sum(1 for item in data.get("profiles",[]) if item.get("usable")))')"
    if ((usable_count > 0)); then
        CERTIFICATE_READY=1
        CERTIFICATE_MESSAGE=""
        return
    fi
    existing_count="$(CERTIFICATE_JSON="$certificate_json" python3 -c 'import json,os
data=json.loads(os.environ["CERTIFICATE_JSON"])
print(sum(1 for item in data.get("profiles",[]) if item.get("exists")))')"
    CERTIFICATE_READY=0
    if ((existing_count > 0)); then
        dates="$(CERTIFICATE_JSON="$certificate_json" python3 -c 'import json,os
data=json.loads(os.environ["CERTIFICATE_JSON"])
print(",".join(str(item["validUntil"]) for item in data.get("profiles",[]) if item.get("exists") and item.get("validUntil")))')"
        CERTIFICATE_MESSAGE="The stored certificate is expired or unreadable.${dates:+ Expired: $dates.} Check the TV date and time too. Import the original certificate before updating; a new one cannot overwrite the installed application."
    else
        CERTIFICATE_MESSAGE='Moonfin is installed, but this directory has no reusable certificate. Import the original certificate before updating; a new one cannot overwrite the existing application.'
    fi
}

mkdir -p -- "$STATE_ROOT"
if ((VARIANT_EXPLICIT == 0)) && [[ -f "$INSTALLER_STATE_PATH" ]]; then
    remembered_variant="$(INSTALLER_STATE_PATH="$INSTALLER_STATE_PATH" python3 -c 'import json,os
try:
    with open(os.environ["INSTALLER_STATE_PATH"],encoding="utf-8-sig") as stream: state=json.load(stream)
    value=state.get("variant", "")
    if value in ("Regular", "Oblong"): print(value)
except (OSError,ValueError,TypeError):
    pass')"
    [[ -z "$remembered_variant" ]] || VARIANT="$remembered_variant"
fi
CLI="$(get_cli)"

printf 'Checking TV %s from %s...\n' "$TV_IP" "$LOCAL_IP"
tv_json="$(invoke_json --attempts 2 tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
[[ "$(json_value "$tv_json" ok)" == true && "$(json_value "$tv_json" tv.ready)" == true ]] || \
    fail 'The TV is not ready. Enable Developer Mode, set Host PC IP, and fully restart it.'
developer_ip="$(json_value "$tv_json" tv.developerIp)"
[[ "$developer_ip" == "$LOCAL_IP" ]] || fail "The TV Host PC IP is $developer_ip, but this computer uses $LOCAL_IP."
printf 'TV ready: %s, Tizen %s.\n' "$(json_value "$tv_json" tv.model)" "$(json_value "$tv_json" tizenVersion)"

printf 'Looking up Moonfin in the signed catalog...\n'
catalog_json="$(invoke_json --attempts "$NETWORK_RETRIES" catalog Moonfin --data-dir "$STATE_ROOT")"
package_json="$(CATALOG_JSON="$catalog_json" python3 -c 'import json,os,re,sys
catalog=json.loads(os.environ["CATALOG_JSON"])
app=next((item for item in catalog.get("apps",[]) if item.get("name")=="Moonfin"),None)
if app is None:
    raise SystemExit(2)
pattern=re.compile(r"^Moonfin_Tizen_"+re.escape(sys.argv[1])+r"_v.+\.wgt$")
files=[item for item in app.get("files",[]) if pattern.match(item.get("file",""))]
if not files:
    raise SystemExit(3)
def semver(item):
    match=re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?",str(item.get("version","")))
    if not match: raise ValueError("invalid semantic version: "+str(item.get("version","")))
    prerelease=match.group(4)
    identifiers=() if prerelease is None else tuple((0,int(part)) if part.isdigit() else (1,part) for part in prerelease.split("."))
    return tuple(map(int,match.group(1,2,3)))+(1 if prerelease is None else 0,identifiers)
print(json.dumps(max(files,key=semver)))' "$VARIANT")" || fail "Moonfin did not publish the $VARIANT variant with a valid semantic version in the current catalog."
package_file="$(json_value "$package_json" file)"
package_version="$(json_value "$package_json" version)"

if ((VALIDATE_ONLY)); then
    printf 'Validation completed: TV ready and Moonfin %s (%s) is available.\n' "$package_version" "$VARIANT"
    exit 0
fi

installed_json="$(invoke_json --attempts 2 installed --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
current_json="$(INSTALLED_JSON="$installed_json" python3 -c 'import json,os
data=json.loads(os.environ["INSTALLED_JSON"])
app=next((item for item in data.get("apps",[]) if item and (item.get("appId")=="MoonfinApp.moonfin" or item.get("catalogApp")=="Moonfin" or item.get("title")=="Moonfin")),None)
print("null" if app is None else json.dumps(app))')"
current_version="$(CURRENT_JSON="$current_json" python3 -c 'import json,os
item=json.loads(os.environ["CURRENT_JSON"]); print("" if item is None else item.get("version", ""))')"
current_file="$(CURRENT_JSON="$current_json" python3 -c 'import json,os
item=json.loads(os.environ["CURRENT_JSON"]); print("" if item is None else item.get("catalogFile", ""))')"
current_app_id="$(CURRENT_JSON="$current_json" python3 -c 'import json,os
item=json.loads(os.environ["CURRENT_JSON"]); print("" if item is None else item.get("appId", ""))')"

version_comparison=""
variant_changed=0
CERTIFICATE_READY=1
CERTIFICATE_MESSAGE=""
if [[ -n "$current_version" ]]; then
    version_comparison="$(compare_versions "$current_version" "$package_version")" || fail "Could not compare versions '$current_version' and '$package_version' semantically."
    known_variant=""
    if [[ -f "$INSTALLER_STATE_PATH" ]]; then
        known_variant="$(INSTALLER_STATE_PATH="$INSTALLER_STATE_PATH" CURRENT_VERSION="$current_version" python3 -c 'import json,os
try:
    with open(os.environ["INSTALLER_STATE_PATH"],encoding="utf-8-sig") as stream: state=json.load(stream)
    if str(state.get("version","")) == os.environ["CURRENT_VERSION"]: print(state.get("variant", ""))
except (OSError,ValueError,TypeError):
    pass')"
    fi
    if [[ -n "$known_variant" && "$known_variant" != "$VARIANT" ]]; then
        variant_changed=1
    elif [[ -z "$known_variant" ]] && ((VARIANT_EXPLICIT)); then
        variant_changed=1
    fi
    get_certificate_readiness
fi

if [[ -n "$current_version" && "$version_comparison" == 1 ]] && ((ALLOW_DOWNGRADE == 0)); then
    fail "The TV has Moonfin $current_version, newer than the catalog ($package_version). Downgrade blocked; use --allow-downgrade only if you intend to go back."
fi

if [[ -n "$current_version" && "$version_comparison" == 0 ]] && ((variant_changed == 0 && FORCE == 0)); then
    if ((CERTIFICATE_READY == 0)); then
        printf 'WARNING: %s\n' "$CERTIFICATE_MESSAGE" >&2
    fi
    printf 'Moonfin %s is already up to date (%s). Use --force to reinstall.\n' "$current_version" "$VARIANT"
    if ((LAUNCH)); then
        [[ -n "$current_app_id" ]] || current_app_id='MoonfinApp.moonfin'
        invoke_json launch "$current_app_id" --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT" >/dev/null
        printf 'Moonfin launched on the TV.\n'
    fi
    exit 0
fi

if [[ -n "$current_version" ]] && ((CERTIFICATE_READY == 0)); then
    fail "$CERTIFICATE_MESSAGE"
fi

if [[ -n "$current_version" && "$version_comparison" == 0 ]] && ((variant_changed)); then
    printf 'Changing Moonfin %s to the %s variant (%s)...\n' "$current_version" "$VARIANT" "$package_file"
elif [[ -n "$current_version" && "$version_comparison" == 1 ]]; then
    printf 'Downgrading Moonfin %s to %s (%s) by explicit request...\n' "$current_version" "$package_version" "$VARIANT"
elif [[ -n "$current_version" ]]; then
    printf 'Updating Moonfin %s to %s (%s)...\n' "$current_version" "$package_version" "$VARIANT"
else
    printf 'Installing Moonfin %s (%s)...\n' "$package_version" "$VARIANT"
fi

install_args=(install Moonfin --file "$package_file" --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT" --keep --json)
((LAUNCH)) && install_args+=(--launch)
((NO_BROWSER)) && install_args+=(--no-browser)
set +e
install_output="$("$CLI" "${install_args[@]}" 2>&1)"
install_status=$?
set -e
printf '%s\n' "$install_output"
if ((install_status != 0)); then
    if grep -Eiq 'author certificate not match|different certificate|certificate mismatch' <<<"$install_output"; then
        fail 'The TV rejected the update because Moonfin was signed with another certificate. Import the original certificate or manually uninstall the existing copy; no application was removed.'
    fi
    if grep -Eiq 'certificate.*expired|expired.*certificate' <<<"$install_output"; then
        fail 'The TV rejected the expired certificate. Check its date and time and import or renew the original certificate; no application was removed.'
    fi
    fail "Installation exited with code $install_status. No application was removed."
fi

verified_json="$(invoke_json --attempts 2 installed --tv "$TV_IP" --local-ip "$LOCAL_IP" --data-dir "$STATE_ROOT")"
verified_version="$(INSTALLED_JSON="$verified_json" python3 -c 'import json,os
data=json.loads(os.environ["INSTALLED_JSON"])
app=next((item for item in data.get("apps",[]) if item and (item.get("appId")=="MoonfinApp.moonfin" or item.get("catalogApp")=="Moonfin" or item.get("title")=="Moonfin")),None)
print("" if app is None else app.get("version",""))')"
[[ -n "$verified_version" ]] || fail 'Apps2Samsung finished, but Moonfin is missing from the refreshed application list.'
[[ "$verified_version" == "$package_version" ]] || fail "Moonfin reports version $verified_version, expected $package_version."
mkdir -p -- "$(dirname -- "$INSTALLER_STATE_PATH")"
INSTALLER_STATE_PATH="$INSTALLER_STATE_PATH" VERIFIED_VERSION="$verified_version" VARIANT="$VARIANT" PACKAGE_FILE="$package_file" CURRENT_APP_ID="${current_app_id:-MoonfinApp.moonfin}" python3 -c 'import json,os
path=os.environ["INSTALLER_STATE_PATH"]
temporary=path+".part"
with open(temporary,"w",encoding="utf-8") as stream:
    json.dump({"appId":os.environ["CURRENT_APP_ID"],"version":os.environ["VERIFIED_VERSION"],"variant":os.environ["VARIANT"],"file":os.environ["PACKAGE_FILE"]},stream,indent=2)
    stream.write("\n")
os.replace(temporary,path)'
printf 'Moonfin %s (%s) installed and verified successfully.\n' "$verified_version" "$VARIANT"
