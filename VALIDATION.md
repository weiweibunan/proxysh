# 验证记录 · 2026-10-31

结果：通过。未连接 VPS，未启动代理服务，未注册 WARP 账号。

- 生成单文件与源码一致；Bash 语法及 `--help` 入口通过。
- 28 项分流断言通过，覆盖指定远程 SRS 与每天更新、AI 专用路由、direct 回退、WireGuard/SOCKS 切换、IPv6、Reserved、PresharedKey、重复应用、无效配置及更新失败保留缓存。
- 7 项更新检查通过：SHA256 不匹配、预发布、非官方 URL、无效配置均拒绝覆盖；有效下载原子安装并保留旧文件；arm64 资产选择正确；拒绝预发布固定版本。
- 使用官方 sing-box 1.14.4、Xray 26.10.29 原生 Windows 构建检查 WireGuard 与 SOCKS 两种生成配置，均通过。
- 从实际协议模板生成原命令的全协议配置，用相同官方内核检查通过，包括有效测试证书下的 Naive 入站。测试文件及证书仅在工作目录，不包含在发布文件中。
- 测试用两个内核的下载压缩包均与 GitHub 官方资产 SHA256 摘要一致。

限制：没有执行 Linux 上的完整安装、systemd/OpenRC 生命周期和真实 WARP 出口连通性测试；Windows 不验证 POSIX 权限位。Xray 对上游保留的 VMess/WebSocket 和 Reality 默认目标打印兼容性提醒，配置检查结果仍为通过。cloudflared 的更新流程经过模拟资产测试，本地未建立真实 Cloudflare 隧道。

官方版本来源：[sing-box 1.14.4](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)、[Xray 26.10.29](https://github.com/XTLS/Xray-core/releases/tag/v26.10.29)、[cloudflared 2026.10.7](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.7)。
