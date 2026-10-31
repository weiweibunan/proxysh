# Official stable release installer. This file is embedded into argosbx.sh.
# Dependencies: bash, curl, jq, sha256sum, tar, unzip, coreutils.
# Public functions return nonzero on failure; they never stop a running service.

agsbx_download() {
    local download_url=$1 download_file=$2
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 \
        --output "$download_file" "$download_url"
}

agsbx_release_error() {
    printf '组件更新失败：%s\n' "$*" >&2
}

agsbx_release_asset() {
    # Print a strictly validated official URL and SHA256, one per line.
    local metadata=$1 asset_name=$2 repo=$3 release_tag=$4 asset_url asset_digest
    asset_url=$(jq -er --arg name "$asset_name" \
        '[.assets[] | select(.name == $name)] | select(length == 1) | .[0].browser_download_url' \
        "$metadata") || return 1
    asset_digest=$(jq -er --arg name "$asset_name" \
        '.assets[] | select(.name == $name) | .digest | select(type == "string")' \
        "$metadata") || return 1
    [[ "$asset_url" == "https://github.com/$repo/releases/download/$release_tag/$asset_name" ]] || return 1
    [[ "$asset_digest" =~ ^sha256:([[:xdigit:]]{64})$ ]] || return 1
    printf '%s\n%s\n' "$asset_url" "${asset_digest#sha256:}"
}

agsbx_update_component() (
    # A subshell scopes cleanup traps without changing the installer's traps.
    local component=$1 repo requested_version install_dir stage release_endpoint
    local release_tag version arch asset_name asset_info asset_url expected actual
    local binary staged_binary config version_output recorded_version
    install_dir="${AGSBX_STATE_DIR:-$HOME/agsbx}"
    case "${cpu:-$(uname -m)}" in
        amd64|x86_64) arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) agsbx_release_error "不支持的架构：${cpu:-$(uname -m)}"; return 1 ;;
    esac
    for binary in curl jq sha256sum mktemp chmod mv cp; do
        command -v "$binary" >/dev/null 2>&1 || {
            agsbx_release_error "缺少依赖 $binary"; return 1;
        }
    done
    case "$component" in
        sing-box)
            repo=SagerNet/sing-box; requested_version=${SINGBOX_VERSION:-latest}
            command -v tar >/dev/null 2>&1 || { agsbx_release_error '缺少 tar'; return 1; }
            ;;
        xray)
            repo=XTLS/Xray-core; requested_version=${XRAY_VERSION:-latest}
            command -v unzip >/dev/null 2>&1 || { agsbx_release_error '缺少 unzip'; return 1; }
            ;;
        cloudflared) repo=cloudflare/cloudflared; requested_version=${CLOUDFLARED_VERSION:-latest} ;;
        *) agsbx_release_error "未知组件 $component"; return 1 ;;
    esac
    mkdir -p "$install_dir" || return 1
    stage=$(mktemp -d "$install_dir/.update-$component.XXXXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$requested_version" == latest ]]; then
        release_endpoint="https://api.github.com/repos/$repo/releases/latest"
    else
        version=${requested_version#v}
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            agsbx_release_error '版本只接受 latest 或稳定版本号（例如 1.14.4）'; return 1;
        }
        if [[ "$component" == cloudflared ]]; then release_tag=$version; else release_tag=v$version; fi
        release_endpoint="https://api.github.com/repos/$repo/releases/tags/$release_tag"
    fi
    agsbx_download "$release_endpoint" "$stage/release.json" || {
        agsbx_release_error "无法读取 $repo 官方发布信息（检查网络或 GitHub API 限流）"; return 1;
    }
    jq -e '.draft == false and .prerelease == false' "$stage/release.json" >/dev/null || {
        agsbx_release_error '拒绝草稿、预发布版本或无效的 GitHub 响应'; return 1;
    }
    release_tag=$(jq -er '.tag_name' "$stage/release.json") || return 1
    version=${release_tag#v}
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        agsbx_release_error "非稳定版本标签 $release_tag"; return 1;
    }
    if [[ "$requested_version" != latest && "$version" != "${requested_version#v}" ]]; then
        agsbx_release_error '发布信息与指定版本不一致'; return 1
    fi
    case "$component" in
        sing-box) asset_name="sing-box-$version-linux-$arch.tar.gz" ;;
        xray)
            if [[ "$arch" == amd64 ]]; then asset_name=Xray-linux-64.zip; else asset_name=Xray-linux-arm64-v8a.zip; fi
            ;;
        cloudflared) asset_name="cloudflared-linux-$arch" ;;
    esac
    asset_info=$(agsbx_release_asset "$stage/release.json" "$asset_name" "$repo" "$release_tag") || {
        agsbx_release_error "官方资产 $asset_name 不存在或缺少有效的 SHA256 摘要"; return 1;
    }
    asset_url=${asset_info%%$'\n'*}
    expected=${asset_info#*$'\n'}
    printf '下载 %s 官方稳定版 %s（%s）\n' "$component" "$release_tag" "$arch"
    agsbx_download "$asset_url" "$stage/package" || return 1
    actual=$(sha256sum "$stage/package") || return 1
    actual=${actual%% *}
    [[ "${actual,,}" == "${expected,,}" ]] || {
        agsbx_release_error "$component SHA256 校验失败，保留现有组件"; return 1;
    }
    staged_binary="$stage/$component"
    case "$component" in
        sing-box)
            tar -xzf "$stage/package" -O "sing-box-$version-linux-$arch/sing-box" > "$staged_binary" || return 1
            ;;
        xray) unzip -p "$stage/package" xray > "$staged_binary" || return 1 ;;
        cloudflared) mv -- "$stage/package" "$staged_binary" || return 1 ;;
    esac
    [[ -s "$staged_binary" ]] && chmod 755 "$staged_binary" || return 1
    version_output=$("$staged_binary" version 2>&1) || {
        agsbx_release_error "$component 无法运行：$version_output"; return 1;
    }
    case "$component" in
        sing-box) recorded_version=$(printf '%s\n' "$version_output" | awk '$1 == "sing-box" && $2 == "version" {print $3; exit}') ;;
        xray) recorded_version=$(printf '%s\n' "$version_output" | awk '$1 == "Xray" {print $2; exit}') ;;
        cloudflared) recorded_version=$(printf '%s\n' "$version_output" | awk '$1 == "cloudflared" && $2 == "version" {print $3; exit}') ;;
    esac
    [[ "$recorded_version" == "$version" ]] || {
        agsbx_release_error "$component 二进制版本与发布信息不一致"; return 1;
    }
    # Validation occurs before replacing the executable, so a failed update
    # leaves both the installed binary and running process intact.
    case "$component" in
        sing-box)
            config="$install_dir/sb.json"
            if [[ -s "$config" ]] && ! "$staged_binary" check -c "$config"; then
                agsbx_release_error '新版 sing-box 未通过现有配置检查，保留旧版本'; return 1
            fi
            ;;
        xray)
            config="$install_dir/xr.json"
            if [[ -s "$config" ]] && ! "$staged_binary" run -test -c "$config"; then
                agsbx_release_error '新版 Xray 未通过现有配置检查，保留旧版本'; return 1
            fi
            ;;
    esac
    if [[ -f "$install_dir/$component" ]]; then
        cp -p -- "$install_dir/$component" "$stage/previous" || return 1
        mv -f -- "$stage/previous" "$install_dir/$component.previous" || return 1
        if [[ -f "$install_dir/$component.version" ]]; then
            cp -p -- "$install_dir/$component.version" "$install_dir/$component.previous.version" || return 1
        fi
    fi
    mv -f -- "$staged_binary" "$install_dir/$component" || return 1
    printf '%s\n' "$release_tag" > "$stage/version" || return 1
    mv -f -- "$stage/version" "$install_dir/$component.version" || return 1
    printf '已安装 %s 官方稳定版：%s\n' "$component" "$release_tag"
)

upxray() { agsbx_update_component xray; }
upsingbox() { agsbx_update_component sing-box; }
upcloudflared() { agsbx_update_component cloudflared; }
