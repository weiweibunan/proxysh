#!/usr/bin/env bash
# Offline regression tests. Never registers WARP, starts services, or uses live HTTP.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
test_temp_base=$(cd -- "${AGSBX_TEST_TMPDIR:-${TMPDIR:-/tmp}}" && pwd -P)
test_dir=$(mktemp -d "$test_temp_base/argosbx-routing-test.XXXXXXXX")
test_dir=$(cd -- "$test_dir" && pwd -P)
cleanup() {
    case "$test_dir" in
        "$test_temp_base"/argosbx-routing-test.*) rm -rf -- "$test_dir" ;;
        *) echo 'Refusing cleanup outside test temp directory' >&2 ;;
    esac
}
trap cleanup EXIT
export AGSBX_STATE_DIR="$test_dir/state"
mkdir -p "$AGSBX_STATE_DIR" "$test_dir/fixtures"

cat > "$test_dir/fixtures/openai.json" <<'JSON'
{"version":3,"rules":[{"domain":["api.openai.com"],"domain_suffix":["openai.com","chatgpt.com"],"domain_keyword":["openai-fixture"],"domain_regex":["^chat[0-9]+\\.openai\\.com$"]}]}
JSON
cat > "$test_dir/fixtures/google-gemini.json" <<'JSON'
{"version":3,"rules":[{"domain":["generativelanguage.googleapis.com"],"domain_suffix":["gemini.google.com"],"domain_regex":["^gemini-[a-z]+\\.google\\.com$"]}]}
JSON

# Override the transport, including direct curl calls. An unexpected URL fails.
curl() {
    local arg output='' url='' fixture
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            -o|--output) output=$1; shift ;;
            --connect-timeout|--max-time|--retry|--retry-delay|--proto|--proto-redir|--header|-H) shift ;;
            https://*) url=$arg ;;
        esac
    done
    case "$url" in
        https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.json) fixture="$test_dir/fixtures/openai.json" ;;
        https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google-gemini.json) fixture="$test_dir/fixtures/google-gemini.json" ;;
        *) printf 'Unexpected HTTP request blocked: %s\n' "$url" >&2; return 88 ;;
    esac
    if [[ -n "$output" ]]; then cp -- "$fixture" "$output"; else cat -- "$fixture"; fi
}
export -f curl
# shellcheck source=../lib/releases.sh
source "$repo_dir/lib/releases.sh"
# shellcheck source=../lib/routing.sh
source "$repo_dir/lib/routing.sh"

test_count=0
assert_json() {
    local description=$1 query=$2 file=$3
    if ! jq -e "$query" "$file" >/dev/null; then
        printf 'FAIL: %s\n' "$description" >&2
        exit 1
    fi
    test_count=$((test_count + 1))
    printf 'ok %d - %s\n' "$test_count" "$description"
}
expect_failure() {
    local description=$1; shift
    if ( "$@" ) >/dev/null 2>&1; then
        printf 'FAIL: %s unexpectedly succeeded\n' "$description" >&2; exit 1
    fi
    test_count=$((test_count + 1))
    printf 'ok %d - %s\n' "$test_count" "$description"
}
check_native_schemas() {
    local mode=$1
    if [[ -n ${SINGBOX_TEST_BINARY:-} ]]; then
        "$SINGBOX_TEST_BINARY" check -c "$test_dir/sb.json" || { echo "FAIL: native sing-box $mode schema" >&2; exit 1; }
        test_count=$((test_count + 1)); printf 'ok %d - native sing-box validates %s config\n' "$test_count" "$mode"
    fi
    if [[ -n ${XRAY_TEST_BINARY:-} ]]; then
        "$XRAY_TEST_BINARY" run -test -c "$test_dir/xr.json" || { echo "FAIL: native Xray $mode schema" >&2; exit 1; }
        test_count=$((test_count + 1)); printf 'ok %d - native Xray validates %s config\n' "$test_count" "$mode"
    fi
}

export WARP_PROFILE="$test_dir/warp-fixture.conf"
cat > "$WARP_PROFILE" <<'INI'
[Interface]
PrivateKey = JC/7sCVMc3wPDR1NB4qwmSDTJJm4CBVrbllS9JD7l2U=
Address = 172.16.0.2/32, 2606:4700:110:1111::2/128
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
PresharedKey = JC/7sCVMc3wPDR1NB4qwmSDTJJm4CBVrbllS9JD7l2U=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [2606:4700:d0::a29f:c001]:2408
Reserved = 1, 2, 3
INI
agsbx_prepare_warp
assert_json 'WARP profile is imported to isolated state' '.mode == "wireguard" and .peer.host == "2606:4700:d0::a29f:c001" and .peer.port == 2408' "$AGSBX_STATE_DIR/warp.json"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '# POSIX permission assertion skipped on Windows\n' ;;
    *) [[ "$(stat -c '%a' "$AGSBX_STATE_DIR/warp.json")" == 600 ]] || { echo 'FAIL: WARP private profile is not mode 600' >&2; exit 1; } ;;
esac

cat > "$test_dir/sb.json" <<'JSON'
{"inbounds":[{"type":"socks","tag":"fixture-inbound","listen":"127.0.0.1","listen_port":19080}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}
JSON
cat > "$test_dir/xr.json" <<'JSON'
{"inbounds":[{"protocol":"socks","tag":"fixture-inbound","listen":"127.0.0.1","port":19081,"settings":{"auth":"noauth"}}],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}
JSON

agsbx_update_rules
agsbx_apply_routing singbox "$test_dir/sb.json"
agsbx_apply_routing xray "$test_dir/xr.json"
assert_json 'sing-box uses the two requested remote SRS rule sets with daily refresh' '[.route.rule_set[] | select(.tag == "geosite-openai" or .tag == "geosite-google-gemini") | select(.type == "remote" and .format == "binary" and .update_interval == "1d" and .http_client == {})] | length == 2' "$test_dir/sb.json"
assert_json 'sing-box matches AI rules to WARP and keeps direct as final' '.route.final == "direct" and any(.route.rules[]; .outbound == "warp-out" and (.rule_set | index("geosite-openai")) != null and (.rule_set | index("geosite-google-gemini")) != null)' "$test_dir/sb.json"
assert_json 'sing-box preserves inbound settings' '.inbounds[0].tag == "fixture-inbound" and .inbounds[0].listen_port == 19080' "$test_dir/sb.json"
assert_json 'sing-box has exactly one WARP endpoint' '[.endpoints[]? | select(.tag == "warp-out")] | length == 1' "$test_dir/sb.json"
assert_json 'Xray routes exact OpenAI domains through WARP' 'any(.routing.rules[]; .outboundTag == "warp-out" and (.domain | index("full:api.openai.com")) != null)' "$test_dir/xr.json"
assert_json 'Xray preserves domain suffix match semantics' 'any(.routing.rules[]; .outboundTag == "warp-out" and (.domain | index("domain:openai.com")) != null and (.domain | index("domain:gemini.google.com")) != null)' "$test_dir/xr.json"
assert_json 'Xray preserves regular expression match semantics' 'any(.routing.rules[]; .outboundTag == "warp-out" and (.domain | index("regexp:^chat[0-9]+\\.openai\\.com$")) != null)' "$test_dir/xr.json"
assert_json 'Xray has no WARP catch-all and keeps direct first' '.outbounds[0].tag == "direct" and all(.routing.rules[] | select(.outboundTag == "warp-out"); (.domain | length) > 0 and (.ip? == null))' "$test_dir/xr.json"
assert_json 'Xray preserves inbound settings and enables sniffing' '.inbounds[0].tag == "fixture-inbound" and .inbounds[0].port == 19081 and .inbounds[0].sniffing.enabled == true' "$test_dir/xr.json"
assert_json 'Xray formats IPv6 WireGuard peer endpoint safely' 'any(.outbounds[]; .protocol == "wireguard" and .settings.peers[0].endpoint == "[2606:4700:d0::a29f:c001]:2408")' "$test_dir/xr.json"
assert_json 'sing-box preserves an optional WireGuard preshared key' '.endpoints[0].peers[0].pre_shared_key == "JC/7sCVMc3wPDR1NB4qwmSDTJJm4CBVrbllS9JD7l2U="' "$test_dir/sb.json"
assert_json 'Xray preserves an optional WireGuard preshared key' 'any(.outbounds[]; .protocol == "wireguard" and .settings.peers[0].preSharedKey == "JC/7sCVMc3wPDR1NB4qwmSDTJJm4CBVrbllS9JD7l2U=")' "$test_dir/xr.json"

jq -S . "$test_dir/sb.json" > "$test_dir/sb.first"
jq -S . "$test_dir/xr.json" > "$test_dir/xr.first"
agsbx_apply_routing singbox "$test_dir/sb.json"
agsbx_apply_routing xray "$test_dir/xr.json"
jq -S . "$test_dir/sb.json" > "$test_dir/sb.second"
jq -S . "$test_dir/xr.json" > "$test_dir/xr.second"
cmp -s "$test_dir/sb.first" "$test_dir/sb.second" || { echo 'FAIL: repeated sing-box route application is not idempotent' >&2; exit 1; }
cmp -s "$test_dir/xr.first" "$test_dir/xr.second" || { echo 'FAIL: repeated Xray route application is not idempotent' >&2; exit 1; }
test_count=$((test_count + 1)); printf 'ok %d - applying routes twice is idempotent\n' "$test_count"
check_native_schemas WireGuard

# A SOCKS WARP deployment must not retain an obsolete WireGuard outbound.
export AGSBX_STATE_DIR="$test_dir/socks-state"
mkdir -p "$AGSBX_STATE_DIR"
unset WARP_PROFILE
export WARP_SOCKS='[::1]:40000'
agsbx_prepare_warp
assert_json 'bracketed IPv6 SOCKS endpoint is parsed without ambiguity' '.mode == "socks" and .server == "::1" and .server_port == 40000' "$AGSBX_STATE_DIR/warp.json"
agsbx_update_rules
agsbx_apply_routing singbox "$test_dir/sb.json"
agsbx_apply_routing xray "$test_dir/xr.json"
assert_json 'sing-box switches WARP to SOCKS without retaining WireGuard' 'any(.outbounds[]; .tag == "warp-out" and .type == "socks" and .server == "::1" and .server_port == 40000) and all(.endpoints[]?; .tag != "warp-out")' "$test_dir/sb.json"
assert_json 'Xray switches WARP to SOCKS without retaining WireGuard' 'any(.outbounds[]; .tag == "warp-out" and .protocol == "socks" and .settings.servers[0].address == "::1" and .settings.servers[0].port == 40000) and all(.outbounds[]; .protocol != "wireguard")' "$test_dir/xr.json"
check_native_schemas SOCKS
unset WARP_SOCKS

prepare_rejected_profile() (
    export WARP_PROFILE=$1 AGSBX_STATE_DIR="$test_dir/rejected-profile-state"
    unset WARP_SOCKS
    agsbx_prepare_warp
)
sed 's/^PrivateKey = .*/PrivateKey = invalid-key/' "$test_dir/warp-fixture.conf" > "$test_dir/invalid-key.conf"
expect_failure 'invalid WireGuard key is rejected' prepare_rejected_profile "$test_dir/invalid-key.conf"
cp "$test_dir/warp-fixture.conf" "$test_dir/multiple-peers.conf"
printf '\n[Peer]\nEndpoint = 127.0.0.1:2408\n' >> "$test_dir/multiple-peers.conf"
expect_failure 'multiple WireGuard peers are rejected' prepare_rejected_profile "$test_dir/multiple-peers.conf"
expect_failure 'endpoint port outside valid range is rejected' agsbx_parse_endpoint '[::1]:70000'

# Updating from a future unsupported match type must preserve the prior good cache.
cp "$AGSBX_STATE_DIR/xray-ai-domains.json" "$test_dir/domains-before-invalid-source.json"
jq '.rules[0].process_name = ["unsupported-fixture"]' "$test_dir/fixtures/openai.json" > "$test_dir/openai-unsupported.json"
mv "$test_dir/openai-unsupported.json" "$test_dir/fixtures/openai.json"
expect_failure 'unsupported remote match condition is rejected' agsbx_update_rules
printf '%s\n' '{"version":3,"rules":[{"domain":[null]}]}' > "$test_dir/fixtures/openai.json"
expect_failure 'null source domains are rejected' agsbx_update_rules
cmp -s "$AGSBX_STATE_DIR/xray-ai-domains.json" "$test_dir/domains-before-invalid-source.json" || { echo 'FAIL: invalid source replaced the prior domain cache' >&2; exit 1; }
test_count=$((test_count + 1)); printf 'ok %d - failed rule update preserves the prior domain cache\n' "$test_count"

# An explicitly missing profile must never fall back to a shared account or HTTP.
expect_failure 'explicitly missing WARP profile is rejected' env WARP_PROFILE="$test_dir/not-found.conf" AGSBX_STATE_DIR="$test_dir/fresh-state" bash -c 'source "$1/lib/releases.sh"; source "$1/lib/routing.sh"; agsbx_prepare_warp' _ "$repo_dir"
printf 'PASS: %d routing assertions\n' "$test_count"
