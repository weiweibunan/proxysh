# Maintained fork of yonggekkk/argosbx, GPL-3.0.
# Protocol generation remains in src/legacy.sh; maintenance is in lib/.
AGSBX_REPO=weiweibunan/proxysh
AGSBX_REF=main
AGSBX_URL="https://raw.githubusercontent.com/$AGSBX_REPO/$AGSBX_REF/argosbx.sh"
AGSBX_VERSION=2026.10.31-r3
umask 077

agsbx_usage() {
    cat <<'HELP'
Argosbx WARP AI 分流版
安装：保留原协议变量（vmpt="" vlpt="" ...），执行 bash argosbx.sh
迁移已有安装：带原协议变量执行 bash argosbx.sh rep
维护：agsbx list | check | rules | upx | ups | upa | update | res | del
  upx / ups / upa：更新 Xray / sing-box / cloudflared 官方最新稳定版
  update：更新所有已安装组件；rules：更新 OpenAI/Gemini 分流规则
WARP：自动读取现有 WireGuard 配置，也可指定 WARP_PROFILE=/path/wgcf.conf
      或 WARP_SOCKS=127.0.0.1:40000（已有 WARP SOCKS 服务）
默认：OpenAI + Gemini 走 WARP，其余直连；不自动注册账号。
稳定版默认动态查询。可设置 XRAY_VERSION、SINGBOX_VERSION、CLOUDFLARED_VERSION 固定版本。
HELP
}
