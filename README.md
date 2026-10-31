# Argosbx · OpenAI / Gemini WARP 分流

基于 [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) 的协议兼容层重构。保留原安装变量、节点链接和订阅生成，增加服务端 AI 域名分流及官方稳定版内核更新。GPL-3.0，保留上游署名及许可证。

- **sing-box**：OpenAI、Gemini 使用 MetaCubeX 远程二进制规则集，`http_client: {}`，每 `1d` 更新。匹配规则先于通用解析，目标通过 WARP 解析及连接。
- **Xray**：读取相同规则源的 JSON，将精确域名、后缀、关键字和正则转换为 Xray 规则；每天刷新。未匹配流量使用 direct。
- **组件更新**：安装及更新时动态查询 SagerNet/sing-box、XTLS/Xray-core、cloudflare/cloudflared 官方最新稳定发布，排除预发布版本。下载后校验官方 GitHub SHA256 摘要，检查二进制版本和配置后才替换。
- **WARP 凭据**：读取服务器已有的 WireGuard 配置，或使用已有 WARP SOCKS 服务。没有共享密钥，不自动注册账号。凭据只保存在服务器，不上传 GitHub。

## 安装

适用于 Linux amd64/arm64。Debian/Ubuntu、Alpine 可自动安装依赖；其他发行版需有 curl、jq、tar、unzip、openssl、coreutils、util-linux。systemd/OpenRC 可持久运行。仅生成脚本，本仓库的发布不会连接或修改你的 VPS。

将已有 WARP 配置放在下列任一位置，或通过 `WARP_PROFILE` 明确指定：

```text
$HOME/agsbx/warp-profile.conf
/etc/wireguard/wgcf.conf
/etc/wireguard/warp.conf
$HOME/wgcf-profile.conf
```

使用你的原协议组合：

```bash
vmpt="" vlpt="" xhpt="" vxpt="" vwpt="" xupt="" xcpt="" \
hypt="" tupt="" nvpt="" anpt="" arpt="" sspt="" \
alns="y" sub="y" argo="vwpt" \
bash <(curl -fsSL https://raw.githubusercontent.com/weiweibunan/proxysh/main/argosbx.sh)
```

空端口变量表示启用该协议并选择随机端口；未设置变量表示不启用。可在命令前加 `WARP_PROFILE=/etc/wireguard/my-warp.conf`。如使用现有 SOCKS 服务，改加 `WARP_SOCKS=127.0.0.1:40000`。

**已有 Argosbx 安装**：在上述命令最后加 `rep`，用原协议变量重新生成配置；执行前备份在 `$HOME/agsbx/backups/`。`rep` 会重启节点，订阅 HTTP 服务沿用上游方式。`alns=y` 沿用上游 ACME 证书流程；Naive 入站需要有效证书，未提供时会跳过该协议。脚本不保证 WARP 出口能访问第三方网站，出口可用性取决于你的账号、网络及服务策略。

## 维护

```bash
agsbx check     # 用已安装内核检查配置
agsbx rules     # 刷新 OpenAI/Gemini 规则并验证、重启 Xray
agsbx upx       # 更新 Xray 官方稳定版
agsbx ups       # 更新 sing-box 官方稳定版
agsbx upa       # 更新 cloudflared 官方稳定版
agsbx update    # 更新全部已安装组件
agsbx list      # 查看节点与订阅
agsbx res       # 重启
```

首次安装后需重连 SSH，或使用 `bash "$HOME/bin/agsbx" check`。上游旧快捷脚本可通过仓库最新地址运行同名维护命令。

更新下载或配置检查失败时保留原二进制；重启失败时尝试恢复 `.previous` 二进制和原配置。新配置生成失败会停止启动并保留错误，备份可用于手动恢复。升级并不等同于无人值守定期更新内核；内核仅在安装或执行更新命令时查询最新稳定版。

可固定版本后再更新：

```bash
SINGBOX_VERSION=1.14.4 agsbx ups
XRAY_VERSION=26.10.29 agsbx upx
CLOUDFLARED_VERSION=2026.10.7 agsbx upa
```

sing-box 原生每一天刷新 `.srs`。Xray 的日更任务在服务器 cron 时区每天 04:17 执行；无 cron 时手动运行 `agsbx rules`。direct 表示服务器默认网络路径；若系统本身已经全局走 WARP，需先调整系统路由才能让其他流量使用原生出口。

## 源码与校验

`argosbx.sh` 是独立文件，无需下载其他模块。维护源码为 `lib/*.sh`、`src/*.sh`，重新生成：

```bash
node scripts/build.cjs
bash -n argosbx.sh
bash tests/test-routing.sh
bash tests/test-releases.sh
node scripts/build.cjs --check
```

规则源：

- [OpenAI SRS](https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs)
- [Gemini SRS](https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google-gemini.srs)
- Xray 使用同目录下对应的 `.json`；规则是社区维护的域名集合，不是全网 AI 流量识别器。

截至 2026-10-31 验证的官方稳定版：sing-box 1.14.4、Xray 26.10.29、cloudflared 2026.10.7。后续安装自动查询届时最新稳定版；若新版本移除现有字段，配置检查会拒绝覆盖。
