# Lifecycle helpers. Configuration is checked before a service is restarted.
agsbx_dependencies() {
    local missing=0 dependency
    for dependency in curl jq tar unzip openssl sha256sum flock crontab busybox; do
        command -v "$dependency" >/dev/null 2>&1 || missing=1
    done
    [[ $missing == 0 ]] && return 0
    if [[ $EUID != 0 ]]; then
        printf '请先安装 curl jq tar unzip openssl coreutils util-linux（或以 root 执行安装）。\n' >&2
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq tar unzip openssl ca-certificates coreutils util-linux busybox cron
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl jq tar unzip openssl ca-certificates coreutils util-linux busybox-extras gcompat
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq tar unzip openssl ca-certificates coreutils util-linux busybox cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq tar unzip openssl ca-certificates coreutils util-linux busybox cronie
    else
        printf '未识别包管理器，请手动安装 curl jq tar unzip openssl coreutils util-linux。\n' >&2
        return 1
    fi
}

agsbx_validate_config() {
    local core=$1 config=$2
    jq -e . "$config" >/dev/null || return 1
    case "$core" in
        xray) "$HOME/agsbx/xray" run -test -c "$config" ;;
        singbox) "$HOME/agsbx/sing-box" check -c "$config" ;;
    esac
}

agsbx_finalize_config() {
    agsbx_apply_routing "$1" "$2" && agsbx_validate_config "$1" "$2" || {
        printf '配置未通过检查，停止启动 %s；备份位于 %s/agsbx/backups。\n' "$1" "$HOME" >&2
        exit 1
    }
}

agsbx_snapshot() {
    local snapshot file
    snapshot="$HOME/agsbx/backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$snapshot" || return 1
    for file in sb.json xr.json warp.json sh.txt; do
        [[ ! -f "$HOME/agsbx/$file" ]] || cp -p "$HOME/agsbx/$file" "$snapshot/" || return 1
    done
    printf '配置备份：%s\n' "$snapshot"
}

agsbx_restart_component() {
    local component=$1 unit command_name pattern
    case "$component" in
        xray) unit=xr; command_name=xray ;;
        sing-box) unit=sb; command_name=sing-box ;;
        cloudflared) unit=argo; command_name=argo ;;
    esac
    if [[ $EUID == 0 ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl restart "$unit" && systemctl is-active --quiet "$unit"
        return $?
    elif [[ $EUID == 0 ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$command_name" restart
        return $?
    fi
    # Match only this installation's executable, never a broad command-line pattern.
    local proc executable process_id
    for proc in /proc/[0-9]*/exe; do
        executable=$(readlink "$proc" 2>/dev/null) || continue
        if [[ "$executable" == "$HOME/agsbx/$component" || "$executable" == "$HOME/agsbx/$component (deleted)" ]]; then
            process_id=${proc#/proc/}; process_id=${process_id%/exe}
            kill -TERM "$process_id" 2>/dev/null
        fi
    done
    case "$component" in
        xray) nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >> "$HOME/agsbx/xray.log" 2>&1 9>&- & ;;
        sing-box) nohup "$HOME/agsbx/sing-box" run -c "$HOME/agsbx/sb.json" >> "$HOME/agsbx/sing-box.log" 2>&1 9>&- & ;;
        cloudflared)
            if [[ -s "$HOME/agsbx/sbargotoken.log" ]]; then
                nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "$(cat "$HOME/agsbx/sbargotoken.log")" >> "$HOME/agsbx/argo.log" 2>&1 9>&- &
            else
                nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url "http://localhost:$(cat "$HOME/agsbx/argoport.log")" > "$HOME/agsbx/argo.log" 2>&1 9>&- &
            fi ;;
    esac
    local started_pid=$!
    sleep 2
    kill -0 "$started_pid" 2>/dev/null
}

agsbx_refresh_rules() {
    agsbx_prepare_warp || return 1
    agsbx_update_rules || return 1
    [[ -f "$HOME/agsbx/xr.json" ]] || return 0
    local backup
    backup=$(mktemp "$HOME/agsbx/.rules-backup.XXXXXXXX") || return 1
    cp -p "$HOME/agsbx/xr.json" "$backup" || return 1
    if ! agsbx_apply_routing xray "$HOME/agsbx/xr.json" || ! agsbx_validate_config xray "$HOME/agsbx/xr.json"; then
        mv -f "$backup" "$HOME/agsbx/xr.json"
        return 1
    fi
    if agsbx_restart_component xray; then rm -f "$backup"; else
        mv -f "$backup" "$HOME/agsbx/xr.json"
        agsbx_restart_component xray || true
        return 1
    fi
}

agsbx_install_rule_schedule() {
    [[ -f "$HOME/agsbx/xr.json" ]] || return 0
    if ! command -v crontab >/dev/null 2>&1; then
        printf '未安装 cron：请自行每日运行 agsbx rules。\n' >&2
        return 0
    fi
    local schedule
    schedule=$(mktemp "$HOME/agsbx/.crontab.XXXXXXXX") || return 1
    { crontab -l 2>/dev/null || true; } | sed '/# argosbx-ai-rules$/d' > "$schedule"
    printf '17 4 * * * /bin/bash "%s/bin/agsbx" rules >> "%s/agsbx/rules-update.log" 2>&1 # argosbx-ai-rules\n' "$HOME" "$HOME" >> "$schedule"
    crontab "$schedule"
    local result=$?
    rm -f "$schedule"
    if [[ $EUID == 0 ]]; then
        if [[ -d /run/systemd/system ]]; then
            systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
        elif command -v rc-service >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || true
        fi
    fi
    return "$result"
}

agsbx_upgrade() {
    local component=$1 core config backup
    [[ -x "$HOME/agsbx/$component" ]] || { printf '未安装 %s。\n' "$component" >&2; return 1; }
    config=
    case "$component" in xray) core=xray; config="$HOME/agsbx/xr.json" ;; sing-box) core=singbox; config="$HOME/agsbx/sb.json" ;; esac
    if [[ -n "$config" && -s "$config" ]]; then
        agsbx_prepare_warp || return 1
        backup=$(mktemp "$HOME/agsbx/.upgrade-config.XXXXXXXX") || return 1
        cp -p "$config" "$backup" || return 1
        if ! agsbx_apply_routing "$core" "$config"; then mv -f "$backup" "$config"; return 1; fi
    fi
    if ! agsbx_update_component "$component"; then
        [[ -z "$backup" ]] || mv -f "$backup" "$config"
        return 1
    fi
    if agsbx_restart_component "$component"; then
        [[ -z "$backup" ]] || rm -f "$backup"
        return 0
    fi
    if [[ -f "$HOME/agsbx/$component.previous" ]]; then
        cp -p "$HOME/agsbx/$component.previous" "$HOME/agsbx/.$component.rollback" && mv -f "$HOME/agsbx/.$component.rollback" "$HOME/agsbx/$component"
        if [[ -f "$HOME/agsbx/$component.previous.version" ]]; then
            cp -p "$HOME/agsbx/$component.previous.version" "$HOME/agsbx/$component.version"
        else
            rm -f "$HOME/agsbx/$component.version"
        fi
    fi
    [[ -z "$backup" ]] || mv -f "$backup" "$config"
    agsbx_restart_component "$component" || true
    printf '%s 更新失败，已恢复可用的旧文件；请查看服务日志。\n' "$component" >&2
    return 1
}

agsbx_main() {
    case "${1:-}" in help|-h|--help) agsbx_usage; return ;; esac
    [[ $(uname -s) == Linux ]] || { printf '此安装器仅在 Linux VPS 上运行。\n' >&2; return 1; }
    agsbx_dependencies || return 1
    mkdir -p "$HOME/agsbx" || return 1
    # A shared lock also protects cron refresh against manual upgrades.
    exec 9> "$HOME/agsbx/.lock"
    flock -n 9 || { printf '另一个 Argosbx 操作正在进行。\n' >&2; return 1; }
    case "${1:-}" in
        check)
            local checked=0
            if [[ -s "$HOME/agsbx/xr.json" ]]; then agsbx_validate_config xray "$HOME/agsbx/xr.json" || return 1; checked=1; fi
            if [[ -s "$HOME/agsbx/sb.json" ]]; then agsbx_validate_config singbox "$HOME/agsbx/sb.json" || return 1; checked=1; fi
            [[ $checked == 1 ]] || { printf '没有已安装的配置。\n' >&2; return 1; }
            return ;;
        rules) agsbx_refresh_rules; return $? ;;
        upx) agsbx_snapshot && agsbx_upgrade xray; return $? ;;
        ups) agsbx_snapshot && agsbx_upgrade sing-box; return $? ;;
        upa) agsbx_snapshot && agsbx_upgrade cloudflared; return $? ;;
        update)
            agsbx_snapshot || return 1
            local component
            for component in xray sing-box cloudflared; do
                [[ ! -x "$HOME/agsbx/$component" ]] || agsbx_upgrade "$component" || return 1
            done
            return ;;
        list|res|del) ;;
        ''|rep)
            agsbx_prepare_warp || return 1
            [[ ! -f "$HOME/agsbx/xray" && ! -f "$HOME/agsbx/xr.json" ]] || agsbx_update_rules || return 1
            agsbx_snapshot || return 1 ;;
        *) agsbx_usage >&2; return 2 ;;
    esac
    agsbx_legacy_main "$@"
}
