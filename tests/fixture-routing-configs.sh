#!/usr/bin/env bash
# Generate isolated behavioral fixtures through the production module APIs.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_dir=$1
warp_port=$2
[[ -z ${AGSBX_TEST_JQ_DIR:-} ]] || export PATH="$AGSBX_TEST_JQ_DIR:$PATH"
export AGSBX_STATE_DIR="$fixture_dir/state"
export WARP_SOCKS="127.0.0.1:$warp_port"
unset WARP_PROFILE
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
agsbx_prepare_warp
agsbx_update_rules
printf '%s\n' '{"inbounds":[{"protocol":"socks","tag":"fixture-in","listen":"127.0.0.1","port":19081,"settings":{"auth":"noauth"}}]}' > "$fixture_dir/xray.json"
printf '%s\n' '{"inbounds":[{"type":"socks","tag":"fixture-in","listen":"127.0.0.1","listen_port":19080}]}' > "$fixture_dir/singbox.json"
agsbx_apply_routing xray "$fixture_dir/xray.json"
agsbx_apply_routing singbox "$fixture_dir/singbox.json"
