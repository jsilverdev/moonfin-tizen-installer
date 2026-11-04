#!/usr/bin/env bash
set -Eeuo pipefail

for command_name in curl python3 sha256sum tar find; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$command_name" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
RELEASE_API='https://api.github.com/repos/Apps2Samsung/Apps2Samsung/releases/latest'
headers=(--header 'Accept: application/vnd.github+json' --header 'User-Agent: moonfin-tizen-installer-contract')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
fi

release_json="$(curl --fail --location --silent --show-error --retry 3 --retry-all-errors "${headers[@]}" "$RELEASE_API")"
asset_json="$(RELEASE_JSON="$release_json" python3 -c 'import json,os,re
release=json.loads(os.environ["RELEASE_JSON"])
pattern=re.compile(r"^Apps2Samsung-cli-v.+-linux-x64\.tar\.gz$")
asset=next((item for item in release.get("assets",[]) if pattern.match(item.get("name",""))),None)
if not asset or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}",asset.get("digest", "")):
    raise SystemExit("stable release has no valid linux-x64 CLI asset")
print(json.dumps(asset))')"
asset_url="$(ASSET_JSON="$asset_json" python3 -c 'import json,os; print(json.loads(os.environ["ASSET_JSON"])["browser_download_url"])')"
asset_digest="$(ASSET_JSON="$asset_json" python3 -c 'import json,os; print(json.loads(os.environ["ASSET_JSON"])["digest"].lower())')"
archive="$TMP_DIR/apps2samsung.tar.gz"
curl --fail --location --show-error --retry 3 --retry-all-errors --output "$archive" "$asset_url"
actual_digest="sha256:$(sha256sum "$archive" | awk '{print tolower($1)}')"
[[ "$actual_digest" == "$asset_digest" ]] || { printf 'CLI digest mismatch\n' >&2; exit 1; }
tar -xzf "$archive" -C "$TMP_DIR"
cli="$(find "$TMP_DIR" -type f -name apps2samsung-cli -print -quit)"
[[ -n "$cli" ]] || { printf 'CLI executable missing from archive\n' >&2; exit 1; }
chmod +x "$cli"

catalog_json="$("$cli" catalog Moonfin --data-dir "$TMP_DIR/state" --json --quiet)"
CATALOG_JSON="$catalog_json" python3 -c 'import json,os,re
data=json.loads(os.environ["CATALOG_JSON"])
assert data.get("ok") is True
app=next((item for item in data.get("apps",[]) if item.get("name")=="Moonfin"),None)
assert app is not None
files=app.get("files",[])
assert any(re.fullmatch(r"Moonfin_Tizen_Regular_v.+\.wgt",item.get("file","")) for item in files)
assert any(re.fullmatch(r"Moonfin_Tizen_Oblong_v.+\.wgt",item.get("file","")) for item in files)
assert all(re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?",str(item.get("version",""))) for item in files)
print("Live catalog contract passed for Moonfin",app.get("tag"))'

cert_json="$("$cli" cert --data-dir "$TMP_DIR/empty-state" --json --quiet)"
CERT_JSON="$cert_json" python3 -c 'import json,os
data=json.loads(os.environ["CERT_JSON"])
assert data.get("ok") is True
profiles=data.get("profiles")
assert isinstance(profiles,list) and profiles
assert all("level" in item and "exists" in item and "usable" in item and "duids" in item for item in profiles)
print("Live certificate JSON contract passed")'
