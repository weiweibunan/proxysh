#!/usr/bin/env bash
# WARP credentials are imported locally; this module never registers accounts.

agsbx_routing_error() { printf 'Argosbx: %s\n' "$*" >&2; return 1; }
agsbx_state_dir() { printf '%s\n' "${AGSBX_STATE_DIR:-$HOME/agsbx}"; }

agsbx_parse_endpoint() {
    local endpoint=$1 host port
    if [[ $endpoint =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
    elif [[ $endpoint =~ ^([^:[:space:]]+):([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
    else
        agsbx_routing_error 'Endpoint 必须是 host:port 或 [IPv6]:port'; return 1
    fi
    [[ $host != *[[:space:]]* && ${#port} -le 5 ]] && ((10#$port > 0 && 10#$port <= 65535)) || {
        agsbx_routing_error 'Endpoint 的地址或端口无效'; return 1;
    }
    jq -cn --arg host "$host" --argjson port "$((10#$port))" '{host:$host,port:$port}'
}

agsbx_validate_warp_json() {
    jq -e '
      def key: type == "string" and test("^[A-Za-z0-9+/]{43}=$");
      if .mode == "socks" then
        (.server | type == "string" and length > 0) and
        (.server_port | type == "number" and floor == . and . > 0 and . <= 65535)
      elif .mode == "wireguard" then
        (.private_key | key) and (.peer.public_key | key) and
        ((.peer.pre_shared_key // "") as $psk | $psk == "" or ($psk | key)) and
        (.addresses | type == "array" and length > 0 and all(.[]; type == "string" and test("^[0-9A-Fa-f.:]+/[0-9]{1,3}$"))) and
        (.peer.host | type == "string" and length > 0) and
        (.peer.port | type == "number" and floor == . and . > 0 and . <= 65535) and
        (.peer.allowed_ips | type == "array" and length > 0) and
        (.peer.reserved | type == "array" and length == 3 and all(.[]; type == "number" and floor == . and . >= 0 and . <= 255))
      else false end
    ' "$1" >/dev/null 2>&1
}

agsbx_prepare_warp() {
    local state profile='' candidate tmp raw endpoint
    state=$(agsbx_state_dir)
    if [[ -z ${WARP_SOCKS:-} ]]; then
        if [[ -n ${WARP_PROFILE:-} ]]; then
            [[ -r $WARP_PROFILE ]] || { agsbx_routing_error "无法读取 WARP_PROFILE: $WARP_PROFILE"; return 1; }
            profile=$WARP_PROFILE
        else
            for candidate in "$state/warp-profile.conf" /etc/wireguard/wgcf.conf /etc/wireguard/warp.conf /etc/wireguard/wgcf-profile.conf "$HOME/wgcf-profile.conf"; do
                if [[ -s $candidate && -r $candidate ]]; then profile=$candidate; break; fi
            done
            if [[ -z $profile && -s $state/warp.json ]]; then
                command -v jq >/dev/null || { agsbx_routing_error '需要 jq 才能读取 WARP 配置'; return 1; }
                agsbx_validate_warp_json "$state/warp.json" || { agsbx_routing_error '已保存的 warp.json 无效，请设置 WARP_PROFILE'; return 1; }
                chmod 600 "$state/warp.json" || return 1
                return 0
            fi
        fi
        [[ -n $profile ]] || {
            agsbx_routing_error "未找到已有 WARP/WireGuard 配置。请设置 WARP_PROFILE=/完整路径/wgcf-profile.conf，或 WARP_SOCKS=127.0.0.1:40000。尚未更改服务。"; return 1;
        }
    fi
    command -v jq >/dev/null || { agsbx_routing_error '需要 jq 才能读取 WARP 配置'; return 1; }
    mkdir -p "$state" || return 1
    chmod 700 "$state" || return 1
    tmp=$(mktemp "$state/.warp.XXXXXX") || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -n ${WARP_SOCKS:-} ]]; then
        endpoint=$(agsbx_parse_endpoint "$WARP_SOCKS") || { rm -f "$tmp"; return 1; }
        jq -cn --argjson ep "$endpoint" '{mode:"socks",server:$ep.host,server_port:$ep.port}' > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        # Parse INI as data, never source/eval it. Reject multiple peers instead of silently selecting one.
        raw=$(awk '
          BEGIN { section=""; peers=0 }
          { sub(/\r$/, ""); sub(/[;#].*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
          /^\[/ { section=tolower($0); if(section=="[peer]") peers++; next }
          index($0,"=") { p=index($0,"="); k=tolower(substr($0,1,p-1)); v=substr($0,p+1); gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v);
            if(section=="[interface]" && (k=="privatekey" || k=="address")) print k "\t" v;
            if(section=="[peer]" && (k=="publickey" || k=="presharedkey" || k=="endpoint" || k=="allowedips" || k=="reserved")) print k "\t" v;
          }
          END { if(peers!=1) exit 3 }
        ' "$profile") || { rm -f "$tmp"; agsbx_routing_error 'WARP 配置必须包含一个 [Interface] 和一个 [Peer]'; return 1; }
        raw=$(printf '%s\n' "$raw" | jq -Rn '
          [inputs | select(length>0) | split("\t") | {key:.[0],value:.[1]}] | from_entries
        ') || { rm -f "$tmp"; return 1; }
        endpoint=$(agsbx_parse_endpoint "$(jq -r '.endpoint // ""' <<< "$raw")") || { rm -f "$tmp"; return 1; }
        jq -cn --argjson ini "$raw" --argjson ep "$endpoint" '
          def csv: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0));
          {mode:"wireguard",private_key:$ini.privatekey,addresses:($ini.address | csv),
           peer:{host:$ep.host,port:$ep.port,public_key:$ini.publickey,pre_shared_key:($ini.presharedkey // ""),
             allowed_ips:(($ini.allowedips // "0.0.0.0/0,::/0") | csv),
             reserved:(($ini.reserved // "0,0,0") | gsub("[\\[\\]]"; "") | csv | map(tonumber))}}
        ' > "$tmp" || { rm -f "$tmp"; agsbx_routing_error '无法解析 WireGuard 配置'; return 1; }
    fi
    agsbx_validate_warp_json "$tmp" || { rm -f "$tmp"; agsbx_routing_error 'WARP 密钥、地址或 reserved 字段无效'; return 1; }
    mv -f "$tmp" "$state/warp.json"
}

agsbx_rules_download() {
    local url=$1 target=$2
    if command -v curl >/dev/null; then
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 90 --retry 2 "$url" -o "$target"
    elif command -v wget >/dev/null; then
        wget --https-only --timeout=90 --tries=3 -q -O "$target" "$url"
    else
        agsbx_routing_error '下载规则需要 curl 或 wget'
    fi
}

agsbx_update_rules() {
    local state tmp category
    state=$(agsbx_state_dir)
    mkdir -p "$state" || return 1
    tmp=$(mktemp -d "$state/.rules.XXXXXX") || return 1
    for category in openai google-gemini; do
        agsbx_rules_download "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/$category.json" "$tmp/$category.json" || {
            rm -rf "$tmp"; agsbx_routing_error '规则下载失败，保留现有规则和服务'; return 1;
        }
    done
    # Reject future unsupported match conditions to avoid accidentally broadening a rule.
    jq -es '
      def arr:
        (if . == null then [] elif type == "array" then . elif type == "string" then [.] else error("invalid domain list") end) |
        if all(.[]; type == "string" and length > 0 and (test("[\\r\\n\\t]") | not)) then . else error("empty or invalid domain") end;
      if all(.[]; (.rules | type == "array" and length > 0) and all(.rules[];
          type == "object" and ((keys - ["domain","domain_suffix","domain_keyword","domain_regex"]) | length == 0)))
      then [ .[].rules[] |
        ((.domain | arr)[] | "full:" + .),
        ((.domain_suffix | arr)[] | ltrimstr(".") | if length > 0 then "domain:" + . else error("empty suffix") end),
        ((.domain_keyword | arr)[] | "keyword:" + .),
        ((.domain_regex | arr)[] | "regexp:" + .)
      ] | unique | if length > 0 then . else error("empty domain set") end
      else error("unsupported source rule") end
    ' "$tmp/openai.json" "$tmp/google-gemini.json" > "$tmp/domains.json" || {
        rm -rf "$tmp"; agsbx_routing_error '远程规则格式不受支持，保留现有规则'; return 1;
    }
    chmod 600 "$tmp/domains.json" || { rm -rf "$tmp"; return 1; }
    mv -f "$tmp/domains.json" "$state/xray-ai-domains.json" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

agsbx_apply_routing() {
    local core=$1 config=$2 state tmp
    state=$(agsbx_state_dir)
    agsbx_validate_warp_json "$state/warp.json" || { agsbx_routing_error '请先读取有效的 WARP 配置'; return 1; }
    [[ -s $config ]] || { agsbx_routing_error "配置不存在: $config"; return 1; }
    tmp=$(mktemp "${config}.route.XXXXXX") || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ $core == xray ]]; then
        if [[ ! -s $state/xray-ai-domains.json ]]; then
            agsbx_update_rules || { rm -f "$tmp"; return 1; }
        fi
        jq --slurpfile wp "$state/warp.json" --slurpfile domains "$state/xray-ai-domains.json" '
          $wp[0] as $w |
          .inbounds |= map(.sniffing = {enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:true}) |
          .outbounds = [{protocol:"freedom",tag:"direct",settings:{}},
            (if $w.mode == "socks" then
              {protocol:"socks",tag:"warp-out",settings:{servers:[{address:$w.server,port:$w.server_port}]}}
            else {protocol:"wireguard",tag:"warp-out",settings:{secretKey:$w.private_key,address:$w.addresses,
              noKernelTun:true,mtu:1280,reserved:$w.peer.reserved,remoteDNS:["1.1.1.1","1.0.0.1"],
              peers:[{publicKey:$w.peer.public_key,preSharedKey:($w.peer.pre_shared_key // ""),allowedIPs:$w.peer.allowed_ips,keepAlive:25,
                endpoint:((if $w.peer.host | contains(":") then "["+$w.peer.host+"]" else $w.peer.host end)+":"+($w.peer.port|tostring))}]}}
            end)] |
          .routing = {domainStrategy:"AsIs",rules:[{type:"field",domain:$domains[0],outboundTag:"warp-out"}]} |
          .dns = {servers:["localhost"]}
        ' "$config" > "$tmp" || { rm -f "$tmp"; return 1; }
    elif [[ $core == singbox ]]; then
        jq --slurpfile wp "$state/warp.json" --arg state "$state" '
          $wp[0] as $w |
          .outbounds = [{type:"direct",tag:"direct"}] |
          .endpoints = [] |
          if $w.mode == "socks" then
            .outbounds += [{type:"socks",tag:"warp-out",server:$w.server,server_port:$w.server_port,version:"5"}]
          else .endpoints = [{type:"wireguard",tag:"warp-out",system:false,mtu:1280,address:$w.addresses,private_key:$w.private_key,
            peers:[{address:$w.peer.host,port:$w.peer.port,public_key:$w.peer.public_key,pre_shared_key:($w.peer.pre_shared_key // ""),allowed_ips:$w.peer.allowed_ips,
              persistent_keepalive_interval:25,reserved:$w.peer.reserved}]}] end |
          .http_clients = [{tag:"rules-direct",detour:"direct"}] |
          .dns = {servers:[{type:"local",tag:"dns-direct"},{type:"tcp",tag:"dns-warp",server:"1.1.1.1",server_port:53,detour:"warp-out"}],
            rules:[{rule_set:["geosite-openai","geosite-google-gemini"],action:"route",server:"dns-warp"}],final:"dns-direct",strategy:"prefer_ipv4"} |
          .route = {default_domain_resolver:"dns-direct",default_http_client:"rules-direct",final:"direct",
            rule_set:[
              {type:"remote",tag:"geosite-openai",format:"binary",url:"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs",http_client:{},update_interval:"1d"},
              {type:"remote",tag:"geosite-google-gemini",format:"binary",url:"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google-gemini.srs",http_client:{},update_interval:"1d"}],
            rules:[{action:"sniff"},{rule_set:["geosite-openai","geosite-google-gemini"],action:"route",outbound:"warp-out"},
              {action:"resolve",server:"dns-direct",strategy:"prefer_ipv4"}]} |
          .experimental = ((.experimental // {}) + {cache_file:{enabled:true,path:($state+"/rules-cache.db")}})
        ' "$config" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"; agsbx_routing_error "未知内核: $core"; return 1
    fi
    mv -f "$tmp" "$config"
}
