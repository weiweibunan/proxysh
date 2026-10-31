#!/usr/bin/env bash
# Generate isolated behavioral fixtures through the production module APIs.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_dir=$1
warp_port=$2
if [[ -n ${AGSBX_TEST_JQ_DIR:-} ]]; then
    fixture_jq_dir=$AGSBX_TEST_JQ_DIR
    if command -v cygpath >/dev/null 2>&1; then fixture_jq_dir=$(cygpath -u "$fixture_jq_dir"); fi
    export PATH="$fixture_jq_dir:$PATH"
fi
export AGSBX_STATE_DIR="$fixture_dir/state"
unset WARP_PROFILE
export WARP_SOCKS="127.0.0.1:$warp_port"
mkdir -p "$AGSBX_STATE_DIR"
cat > "$fixture_dir/openai.json" <<'JSON'
{"version":3,"rules":[{"domain":["exact.ai.fixture"],"domain_suffix":["openai.com","chatgpt.com",".subonly.ai.fixture"],"domain_keyword":["keyword-ai"],"domain_regex":"^regex-[0-9]+\\.ai\\.fixture$"}]}
JSON
cat > "$fixture_dir/google-gemini.json" <<'JSON'
{"version":3,"rules":[{"domain":["generativelanguage.googleapis.com"],"domain_suffix":["gemini.google.com"]}]}
JSON
source "$repo_dir/lib/routing.sh"
agsbx_rules_download() {
    local category=${1##*/}
    case "$category" in openai.json|google-gemini.json) cp "$fixture_dir/$category" "$2" ;; *) return 88 ;; esac
}
printf '%s\n' '{"inbounds":[{"protocol":"socks","tag":"fixture-in","listen":"127.0.0.1","port":19081,"settings":{"auth":"noauth"}}]}' > "$fixture_dir/xray.json"
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"fixture-in","listen":"127.0.0.1","listen_port":19080}]}' > "$fixture_dir/singbox.json"
if [[ ${AGSBX_TEST_SHARED:-0} == 1 ]]; then
    unset WARP_SOCKS
    export WARP_PROFILE="$fixture_dir/warp-fixture.conf"
    cat > "$WARP_PROFILE" <<'INI'
[Interface]
PrivateKey = JC/7sCVMc3wPDR1NB4qwmSDTJJm4CBVrbllS9JD7l2U=
Address = 172.16.0.2/32, 2606:4700:110:1111::2/128
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:2408
Reserved = 1, 2, 3
INI
    cp "$fixture_dir/xray.json" "$AGSBX_STATE_DIR/xr.json"
    cp "$fixture_dir/singbox.json" "$AGSBX_STATE_DIR/sb.json"
fi
agsbx_prepare_warp
agsbx_update_rules
if [[ ${AGSBX_TEST_SHARED:-0} == 1 ]]; then
    agsbx_apply_routing xray "$AGSBX_STATE_DIR/xr.json"
    agsbx_apply_routing singbox "$AGSBX_STATE_DIR/sb.json"
    cp "$AGSBX_STATE_DIR/xr.json" "$fixture_dir/xray.json"
    cp "$AGSBX_STATE_DIR/sb.json" "$fixture_dir/singbox.json"
else
    agsbx_apply_routing xray "$fixture_dir/xray.json"
    agsbx_apply_routing singbox "$fixture_dir/singbox.json"
fi
