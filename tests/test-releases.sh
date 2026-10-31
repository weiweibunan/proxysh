#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/lib/releases.sh"
for dependency in jq tar sha256sum; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 1; }
done
test_temp_base=$(cd -- "${AGSBX_TEST_TMPDIR:-${TMPDIR:-/tmp}}" && pwd -P)
test_root=$(mktemp -d "$test_temp_base/argosbx-release-tests.XXXXXXXX")
test_root=$(cd -- "$test_root" && pwd -P)
cleanup() {
    case "$test_root" in
        "$test_temp_base"/argosbx-release-tests.*) rm -rf -- "$test_root" ;;
        *) printf 'Refusing cleanup outside test temp directory\n' >&2 ;;
    esac
}
trap cleanup EXIT
export AGSBX_STATE_DIR="$test_root/state"
export TEST_LOG="$test_root/config-check.log"
export TEST_CONFIG_FAIL=0
mkdir -p "$AGSBX_STATE_DIR" "$test_root/package"
cpu=amd64

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" > "$test_root/output.log" 2>&1; then fail "unexpected success: $*"; fi; }
expect_old() {
    [[ $(cat "$AGSBX_STATE_DIR/$1") == old-binary ]] || fail "old $1 replaced on failure"
}
metadata() {
    local repo=$1 tag=$2 name=$3 digest=$4 prerelease=${5:-false} url=${6:-}
    [[ -n "$url" ]] || url="https://github.com/$repo/releases/download/$tag/$name"
    jq -n --arg tag "$tag" --arg name "$name" --arg digest "$digest" --arg url "$url" \
        --argjson prerelease "$prerelease" \
        '{tag_name:$tag,draft:false,prerelease:$prerelease,assets:[{name:$name,digest:$digest,browser_download_url:$url}]}' \
        > "$test_root/release.json"
}
# Fixtures replace only the network transport. The production release parser,
# URL restriction, hashing, extraction, candidate checks and replacement run.
agsbx_download() {
    case "$1" in
        https://api.github.com/*) cp "$test_root/release.json" "$2" ;;
        *) printf '%s\n' "$1" >> "$test_root/downloads.log"; cp "$test_root/asset" "$2" ;;
    esac
}

printf 'old-binary\n' > "$AGSBX_STATE_DIR/cloudflared"
cat > "$test_root/asset" <<'BINARY'
#!/usr/bin/env bash
printf 'cloudflared version 2026.10.7 (built test)\n'
BINARY
digest=$(sha256sum "$test_root/asset"); digest="sha256:${digest%% *}"
metadata cloudflare/cloudflared 2026.10.7 cloudflared-linux-amd64 "sha256:$(printf '%064d' 0)"
expect_fail upcloudflared
expect_old cloudflared
printf 'ok - digest mismatch retains installed executable\n'

metadata cloudflare/cloudflared 2026.10.7 cloudflared-linux-amd64 "$digest" true
expect_fail upcloudflared
expect_old cloudflared
printf 'ok - prerelease is rejected\n'

metadata cloudflare/cloudflared 2026.10.7 cloudflared-linux-amd64 "$digest" false \
    https://github.com/untrusted/cloudflared/releases/download/2026.10.7/cloudflared-linux-amd64
expect_fail upcloudflared
expect_old cloudflared
printf 'ok - nonofficial asset URL is rejected\n'

metadata cloudflare/cloudflared 2026.10.7 cloudflared-linux-amd64 "$digest"
upcloudflared > "$test_root/output.log"
[[ $(cat "$AGSBX_STATE_DIR/cloudflared.previous") == old-binary ]] || fail 'previous cloudflared not preserved'
[[ $(cat "$AGSBX_STATE_DIR/cloudflared.version") == 2026.10.7 ]] || fail 'version record incorrect'
printf 'ok - verified official cloudflared installs atomically with previous copy\n'

cpu=arm64
printf 'old-binary\n' > "$AGSBX_STATE_DIR/sing-box"
printf '{"fixture":"unchanged"}\n' > "$AGSBX_STATE_DIR/sb.json"
config_digest=$(sha256sum "$AGSBX_STATE_DIR/sb.json")
mkdir -p "$test_root/package/sing-box-1.14.4-linux-arm64"
cat > "$test_root/package/sing-box-1.14.4-linux-arm64/sing-box" <<'BINARY'
#!/usr/bin/env bash
case "$1" in
    version) printf 'sing-box version 1.14.4\n' ;;
    check)
        printf 'checked-before-install:%s\n' "$(cat "$AGSBX_STATE_DIR/sing-box")" >> "$TEST_LOG"
        [[ "$TEST_CONFIG_FAIL" == 0 ]]
        ;;
    *) exit 1 ;;
esac
BINARY
tar -czf "$test_root/asset" -C "$test_root/package" sing-box-1.14.4-linux-arm64/sing-box
digest=$(sha256sum "$test_root/asset"); digest="sha256:${digest%% *}"
metadata SagerNet/sing-box v1.14.4 sing-box-1.14.4-linux-arm64.tar.gz "$digest"
TEST_CONFIG_FAIL=1
expect_fail upsingbox
expect_old sing-box
[[ $(sha256sum "$AGSBX_STATE_DIR/sb.json") == "$config_digest" ]] || fail 'config changed during failed upgrade'
[[ $(cat "$TEST_LOG") == checked-before-install:old-binary ]] || fail 'candidate did not validate before replacement'
printf 'ok - invalid config retains executable and config\n'

TEST_CONFIG_FAIL=0
upsingbox > "$test_root/output.log"
[[ $(cat "$AGSBX_STATE_DIR/sing-box.previous") == old-binary ]] || fail 'previous sing-box not preserved'
[[ $("$AGSBX_STATE_DIR/sing-box" version) == 'sing-box version 1.14.4' ]] || fail 'candidate not installed'
[[ $(tail -n 1 "$test_root/downloads.log") == */sing-box-1.14.4-linux-arm64.tar.gz ]] || fail 'arm64 asset not selected'
[[ $(sha256sum "$AGSBX_STATE_DIR/sb.json") == "$config_digest" ]] || fail 'config changed during valid upgrade'
printf 'ok - arm64 official archive selection and candidate validation\n'

SINGBOX_VERSION=1.14.4-beta.1 expect_fail upsingbox
printf 'ok - prerelease pin syntax is rejected\n'
printf 'All release module tests passed.\n'
