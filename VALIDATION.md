# 验证记录 · 2026-10-31

结果：通过。未连接或安装到 VPS，未注册 WARP 账号。本地流量测试会临时启动两个内核，仅监听回环地址并连接本地记录出口。

- 生成单文件与源码一致；Bash 语法及 `--help` 入口通过。
- 31 项分流断言通过，覆盖指定远程 SRS 与每天更新、AI 专用路由、direct 回退、WireGuard/SOCKS 切换、IPv6、Reserved、PresharedKey、重复应用、无效配置及更新失败保留缓存，并新增 Xray 前导点后缀的边界和正则转义检查。
- 7 项更新检查通过：SHA256 不匹配、预发布、非官方 URL、无效配置均拒绝覆盖；有效下载原子安装并保留旧文件；arm64 资产选择正确；拒绝预发布固定版本。
- 使用官方 sing-box 1.14.4、Xray 26.10.29 原生 Windows 构建检查 WireGuard 与 SOCKS 两种生成配置，均通过。
- 从实际协议模板生成原命令的全协议配置，用相同官方内核检查通过，包括有效测试证书下的 Naive 入站。测试文件及证书仅在工作目录，不包含在发布文件中。
- 测试用两个内核的下载压缩包均与 GitHub 官方资产 SHA256 摘要一致。

## r2：实际流量验证

新增 `test-routing-behavior.cjs`，通过生产模块生成配置，再使用两个本地 SOCKS 标记出口记录实际选择的路由与目标。sing-box 的本地 SRS 由同一份规则 JSON 通过官方内核编译，仅替换规则下载位置、测试 DNS 和出站传输地址，不替换匹配规则。

使用官方 Xray 26.10.29、sing-box 1.14.4 原生构建完成 **30 项实际流量断言，全部通过**：

- 精确域名及其子域名反例、后缀根域名/子域名/标签边界、关键字、正则及反例。
- Gemini 的精确匹配和后缀匹配，普通 Google 使用 direct。
- `.subonly.ai.fixture` 的根域名走 direct，子域名走 WARP。修复前已复现 Xray 错误地让根域名走 WARP，修复后两内核均正确。
- 原始域名请求选择 WARP，并将域名交给 SOCKS 出口。
- 原始 IP 请求带 AI HTTP Host 或 TLS SNI 时选择 WARP，实际目标仍为原始 IP。两内核行为一致，不声称这类请求会重新通过 WARP DNS 解析。

以上行为测试不连接公网网站或真实 WARP。GitHub CI 新增 Linux 上的同一行为测试，下载的固定官方测试内核同样执行 SHA256 检查。

限制：没有执行 Linux 上的完整安装、systemd/OpenRC 生命周期和真实 WARP 出口连通性测试；Windows 不验证 POSIX 权限位。Xray 对上游保留的 VMess/WebSocket 和 Reality 默认目标打印兼容性提醒，配置检查结果仍为通过。cloudflared 的更新流程经过模拟资产测试，本地未建立真实 Cloudflare 隧道。

官方版本来源：[sing-box 1.14.4](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)、[Xray 26.10.29](https://github.com/XTLS/Xray-core/releases/tag/v26.10.29)、[cloudflared 2026.10.7](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.7)。
