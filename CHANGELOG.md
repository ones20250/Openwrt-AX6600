# 更改记录

本文件记录 `ax6600-custom-build` 分支相对于上游 AX6600 构建方案的定制内容。

## [Unreleased] - AX6600 Custom Build

### 构建与 CI

- 保留原项目 `QCA-ALL.yml` / `WRT-CORE.yml` / `WRT-TEST.yml` 的构建架构。
- 构建源码默认保持 `ones20250/immortalwrt_ipq`，避免无必要地更换 IPQ 平台底座。
- `Scripts/Packages.sh` 统一负责第三方组件接入，并记录实际克隆 commit。
- PURE / PLUS 通过 `WRT_PROFILE` 隔离，避免两套配置互相污染。
- 构建过程输出 `package-versions.txt`，用于追踪第三方组件版本。

### LuCI 与硬件组件

- 新增 `eamonxg/luci-theme-aurora`，作为现代化 LuCI 主题路线。
- 使用指定的 `unraveloop/JDC-AX6600-Athena-LED-Controller`，替换旧 Athena LED 接入方式。
- 增加 `timsaya/luci-app-bandix-plus` 与 `timsaya/openwrt-bandix-plus`。
- Bandix Plus 定位为**流量观察**，不默认启用限速/QoS，避免与 NSS / hardware flow offloading 的性能目标冲突。

### NSS / 内核 / 网络

- 保持 Qualcomm NSS 硬件加速路线。
- 保持 `firewall4` + nftables。
- 补齐 dae / Podman 所需的 veth 能力。
- 保留 nftables TProxy / TUN 相关内核能力。
- 目标内核路线为 Linux 6.6 LTS，但 NSS patch 与驱动兼容性优先；如果实际源码证明 NSS 不兼容 6.6，不会强行升级内核。
- 增加/检查 BPF 与 BTF 能力，为 dae 和 Bandix Plus 提供运行基础。
- 保持 IPv4 + 原生 IPv6、WAN DHCPv6-PD、LAN RA / DHCPv6 路线。

### dae / 透明代理

- 接入 `kenzok8/openwrt-daede`。
- 采用路由器透明接管方式，客户端不需要手动填写 HTTP/SOCKS 代理端口。
- 分流目标为：国内直连、国外按规则交给 dae。
- 使用项目兼容的 geosite / geoip 规则。
- **不在仓库中预置代理节点、订阅 URL、UUID、密钥或账号。**
- 节点配置由用户后续自行导入。
- 透明代理设计避免把所有普通流量无条件送入用户态代理；普通可卸载流量优先保持 NSS 路径。

### DNS

- 接入 mosdns / smartdns，并保留 dnsmasq 负责 DHCP 与基础 DNS 能力。
- 目标为国内/国外 DNS 分流、污染净化和 CDN 优化。
- DNS 规则来源使用项目兼容的 geosite / geoip，不绑定某个固定第三方规则服务。
- 编译和启动配置必须避免 53 端口冲突与 DNS 回环。
- IPv4 / IPv6 DNS 均纳入分流设计，避免 IPv6 绕过策略。

### Podman / 存储

- 接入 OpenWrt Podman 运行环境。
- 接入 `Zerogiven-OpenWRT-Packages/luci-app-podman` 作为 LuCI 管理面板。
- Podman 数据、镜像和日志推荐使用 USB + ext4 外置存储。
- 不集成 Tailscale。

### Wi-Fi / BDF

- 保持 Qualcomm Wi-Fi 驱动路线。
- 使用 OpenWrt `firmware_qca-wireless` 体系提供兼容 BDF；不把整个 BDF 源码仓库直接复制进固件。
- 最终 AX6600 board file / BDF 以实际 target 和上游包内容为准。

### 文档与可维护性

- README 增加定制分支的功能说明、性能原则、DNS/dae 架构、组件来源和实机验证清单。
- 所有第三方仓库集中记录，便于后续升级与排查。
- 关键配置和脚本增加中文注释，明确“为什么开启/为什么关闭”，避免只堆配置而无法维护。

## 验证原则

每次较大的上游同步或第三方组件升级，都应重新验证：

1. `.config` 是否存在冲突；
2. NSS 是否成功启用并实际工作；
3. hardware flow offloading 是否正常；
4. Wi-Fi 三频是否正常；
5. IPv6 是否正常；
6. DNS 是否出现端口冲突或回环；
7. dae 国内直连 / 国外代理是否符合预期；
8. Bandix 观察是否影响 NSS 性能；
9. Podman / veth / nftables 是否正常；
10. 镜像大小是否仍符合 AX6600 当前分区布局。

> 本文件记录的是构建工程变化，不代表所有功能已经完成实机验证。实机验证结果应在对应 Release 或后续条目中补充。