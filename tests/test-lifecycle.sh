#!/usr/bin/env bash
# Isolated orchestration simulation. No real network, service or package commands run.
# The adapter redirects only literal $HOME/agsbx paths in a copied runtime module;
# HOME remains unchanged, and production control flow is executed without rewriting it.
set -eo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_temp_base=$(cd -- "${AGSBX_TEST_TMPDIR:-${TMPDIR:-/tmp}}" && pwd -P)
test_root=$(mktemp -d "$test_temp_base/argosbx-lifecycle-tests.XXXXXXXX")
test_root=$(cd -- "$test_root" && pwd -P)
cleanup() {
    case "$test_root" in
        "$test_temp_base"/argosbx-lifecycle-tests.*) rm -rf -- "$test_root" ;;
        *) printf 'Refusing cleanup outside test temp directory\n' >&2 ;;
    esac
}
trap cleanup EXIT
sed 's|\$HOME/agsbx|\$AGSBX_STATE_DIR|g' "$repo_dir/lib/runtime.sh" > "$test_root/runtime.fixture.sh"
source "$test_root/runtime.fixture.sh"
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
original_home=$HOME
test_count=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { test_count=$((test_count + 1)); printf 'ok %d - %s\n' "$test_count" "$1"; }
expect_fail() { if "$@" > "$case_dir/output.log" 2>&1; then fail "unexpected success: $*"; fi; }
assert_old_config() { cmp -s "$AGSBX_STATE_DIR/xr.json" "$case_dir/original-config" || fail 'original config not restored'; }
prepare_case() {
    case_dir="$test_root/case-$1"
    export AGSBX_STATE_DIR="$case_dir/state"
    mkdir -p "$AGSBX_STATE_DIR"
    printf '#!/bin/sh\n# old-binary\n' > "$AGSBX_STATE_DIR/xray"
    chmod 700 "$AGSBX_STATE_DIR/xray"
    printf '{"generation":"old"}\n' > "$AGSBX_STATE_DIR/xr.json"
    cp "$AGSBX_STATE_DIR/xr.json" "$case_dir/original-config"
    printf 'old-version\n' > "$AGSBX_STATE_DIR/xray.version"
    : > "$case_dir/events"
    prepare_fail=0; apply_fail=0; download_fail=0; validate_fail=0
    rules_download_fail=0; restart_fail_first=0; restart_count=0; restart_fail_on=0
    apply_fail_core=; validate_fail_core=
}
prepare_dual_case() {
    prepare_case "$1"
    printf '#!/bin/sh\n# old-sing-binary\n' > "$AGSBX_STATE_DIR/sing-box"
    chmod 700 "$AGSBX_STATE_DIR/sing-box"
    printf '{"generation":"old-sing","endpoints":[{"type":"wireguard","tag":"warp-out"}]}\n' > "$AGSBX_STATE_DIR/sb.json"
    cp "$AGSBX_STATE_DIR/sb.json" "$case_dir/original-sing-config"
    printf 'old-sing-version\n' > "$AGSBX_STATE_DIR/sing-box.version"
}
assert_old_both() {
    assert_old_config
    cmp -s "$AGSBX_STATE_DIR/sb.json" "$case_dir/original-sing-config" || fail 'original sing-box config not restored'
}
agsbx_prepare_warp() {
    printf 'prepare\n' >> "$case_dir/events"
    [[ $prepare_fail == 0 ]]
}
agsbx_apply_routing() {
    printf 'apply:%s\n' "$1" >> "$case_dir/events"
    printf '{"generation":"new"}\n' > "$2"
    [[ $apply_fail == 0 && $apply_fail_core != "$1" ]]
}
agsbx_update_component() {
    printf 'download:%s\n' "$1" >> "$case_dir/events"
    [[ $download_fail == 0 ]] || return 1
    printf 'candidate-check:%s\n' "$1" >> "$case_dir/events"
    [[ $validate_fail == 0 ]] || return 1
    cp -p "$AGSBX_STATE_DIR/$1" "$AGSBX_STATE_DIR/$1.previous"
    cp -p "$AGSBX_STATE_DIR/$1.version" "$AGSBX_STATE_DIR/$1.previous.version"
    printf '#!/bin/sh\n# new-binary\n' > "$AGSBX_STATE_DIR/$1"
    printf 'new-version\n' > "$AGSBX_STATE_DIR/$1.version"
}
agsbx_restart_component() {
    local config_file=xr.json
    [[ $1 != sing-box ]] || config_file=sb.json
    restart_count=$((restart_count + 1))
    printf 'restart:%s:%s:%s:%s\n' "$1" "$(tail -n 1 "$AGSBX_STATE_DIR/$1" | sed 's/^# //')" "$(cat "$AGSBX_STATE_DIR/$config_file")" "$(cat "$AGSBX_STATE_DIR/$1.version")" >> "$case_dir/events"
    [[ ( $restart_fail_first == 0 || $restart_count != 1 ) && $restart_count != "$restart_fail_on" ]]
}
agsbx_validate_config() {
    printf 'validate:%s\n' "$1" >> "$case_dir/events"
    [[ $validate_fail == 0 && $validate_fail_core != "$1" ]]
}
agsbx_update_rules() {
    printf 'rules-download\n' >> "$case_dir/events"
    [[ $rules_download_fail == 0 ]]
}
assert_event_sequence() {
    local expected=$1 actual
    actual=$(sed 's/:.*//' "$case_dir/events" | tr '\n' ',')
    [[ $actual == "$expected" ]] || fail "event order: expected $expected, got $actual"
}
assert_no_restart() {
    if sed -n '/^restart:/p' "$case_dir/events" | read -r _; then fail 'unexpected restart'; fi
}

prepare_case download-failure
download_fail=1
expect_fail agsbx_upgrade xray
assert_old_config; assert_no_restart
[[ $(tail -n 1 "$AGSBX_STATE_DIR/xray") == '# old-binary' ]] || fail 'download failure changed executable'
assert_event_sequence 'prepare,apply,download,'
pass 'download failure restores config and never restarts the existing core'

prepare_case validation-failure
validate_fail=1
expect_fail agsbx_upgrade xray
assert_old_config; assert_no_restart
[[ $(tail -n 1 "$AGSBX_STATE_DIR/xray") == '# old-binary' ]] || fail 'validation failure changed executable'
assert_event_sequence 'prepare,apply,download,candidate-check,'
pass 'candidate validation failure restores config before any restart'

prepare_case restart-failure
restart_fail_first=1
expect_fail agsbx_upgrade xray
assert_old_config
[[ $(tail -n 1 "$AGSBX_STATE_DIR/xray") == '# old-binary' ]] || fail 'restart failure did not restore executable'
[[ $(cat "$AGSBX_STATE_DIR/xray.version") == old-version ]] || fail 'restart failure did not restore version record'
[[ $restart_count == 2 ]] || fail 'rollback did not restart old version exactly once'
tail -n 1 "$case_dir/events" | sed -n '/restart:xray:old-binary:{"generation":"old"}:old-version/p' | read -r _ || fail 'rollback restart used new files'
pass 'failed candidate restart restores executable, config and version before restarting old core'

prepare_case success
agsbx_upgrade xray > "$case_dir/output.log" 2>&1
[[ $(tail -n 1 "$AGSBX_STATE_DIR/xray") == '# new-binary' ]] || fail 'successful update did not retain candidate'
[[ $(cat "$AGSBX_STATE_DIR/xray.version") == new-version ]] || fail 'successful update lost version'
[[ $restart_count == 1 ]] || fail 'successful update restart count'
assert_event_sequence 'prepare,apply,download,candidate-check,restart,'
pass 'successful update changes files only after candidate check and restarts once'

prepare_case apply-failure
apply_fail=1
expect_fail agsbx_upgrade xray
assert_old_config; assert_no_restart
assert_event_sequence 'prepare,apply,'
pass 'route conversion failure restores original config without downloading or restarting'

prepare_case rules-invalid
validate_fail=1
expect_fail agsbx_refresh_rules
assert_old_config; assert_no_restart
assert_event_sequence 'prepare,rules-download,apply,validate,'
pass 'invalid refreshed rules restore original config without restarting'

prepare_case rules-restart-failure
restart_fail_first=1
expect_fail agsbx_refresh_rules
assert_old_config
[[ $restart_count == 2 ]] || fail 'rules rollback restart count'
tail -n 1 "$case_dir/events" | sed -n '/restart:xray:old-binary:{"generation":"old"}:old-version/p' | read -r _ || fail 'rule rollback restarted new config'
pass 'rules restart failure restores old config before recovery restart'

prepare_case rules-download-failure
rules_download_fail=1
expect_fail agsbx_refresh_rules
assert_old_config; assert_no_restart
assert_event_sequence 'prepare,rules-download,'
pass 'rule download failure leaves config and existing service untouched'

prepare_case missing-warp
prepare_fail=1
expect_fail agsbx_upgrade xray
assert_old_config; assert_no_restart
assert_event_sequence 'prepare,'
pass 'missing WARP stops before conversion, download or service calls'

prepare_dual_case shared-success
agsbx_reconcile_routes > "$case_dir/output.log" 2>&1
assert_event_sequence 'apply,apply,validate,validate,restart,restart,'
[[ $(head -n 4 "$case_dir/events") == $'apply:xray\napply:singbox\nvalidate:xray\nvalidate:singbox' ]] || fail 'dual configs were not applied/validated Xray first'
[[ $(sed -n '5s/:.*//p' "$case_dir/events") == restart && $(sed -n '5p' "$case_dir/events") == restart:xray:* && $(sed -n '6p' "$case_dir/events") == restart:sing-box:* ]] || fail 'shared gateway was not restarted before sing-box'
pass 'dual route migration validates both configs before restarting gateway then sing-box'

prepare_dual_case shared-validation-failure
validate_fail_core=singbox
expect_fail agsbx_reconcile_routes
assert_old_both; assert_no_restart
assert_event_sequence 'apply,apply,validate,validate,'
pass 'sibling validation failure restores both configs without touching services'

prepare_dual_case shared-conversion-failure
apply_fail_core=singbox
expect_fail agsbx_reconcile_routes
assert_old_both; assert_no_restart
assert_event_sequence 'apply,apply,'
pass 'sibling conversion failure restores both configs before validation or restart'

prepare_dual_case shared-restart-failure
restart_fail_on=2
expect_fail agsbx_reconcile_routes
assert_old_both
[[ $restart_count == 4 ]] || fail 'shared rollback must attempt both old services'
[[ $(sed -n '7p' "$case_dir/events") == 'restart:xray:old-binary:{"generation":"old"}:old-version' ]] || fail 'old gateway recovery started before restoring config'
[[ $(sed -n '8p' "$case_dir/events") == 'restart:sing-box:old-sing-binary:{"generation":"old-sing","endpoints":[{"type":"wireguard","tag":"warp-out"}]}:old-sing-version' ]] || fail 'old sing-box recovery started before restoring config'
pass 'second restart failure restores both configs then recovers gateway and sibling'

prepare_dual_case legacy-upgrade-guard
printf '{"mode":"wireguard"}\n' > "$AGSBX_STATE_DIR/warp.json"
expect_fail agsbx_upgrade sing-box
assert_old_both; assert_no_restart
assert_event_sequence 'prepare,'
sed -n '/agsbx rules/p' "$case_dir/output.log" | read -r _ || fail 'legacy upgrade guard lacks migration instruction'
pass 'legacy duplicate-WireGuard deployment blocks single-core update before mutation'

[[ $HOME == "$original_home" ]] || fail 'HOME changed during simulation'
pass 'simulation never repurposes HOME'
printf 'PASS: %d isolated lifecycle scenarios\n' "$test_count"
