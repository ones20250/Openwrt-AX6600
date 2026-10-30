# 🚀 OpenWrt AX6600 / IPQ60xx Router Firmware (Cloud Build + PPE Acceleration)

OpenWrt / AX6600 / IPQ6010 / JDCloud RE-CS-02 / PPE / Router Firmware / Cloud Build
> 基于 OpenWrt / ImmortalWrt 的定制固件，适配 JDCloud RE-CS-02（京东云雅典娜 AX6600），全面迁移至 Linux 6.18 LTS 内核，集成 Qualcomm PPE 开源硬件加速、SONiC FullCone NAT1 与 GitHub Actions 极速云编译

[![Stars](https://img.shields.io/github/stars/ones20250/Openwrt-AX6600?style=flat&logo=github&label=Stars)](https://github.com/ones20250/Openwrt-AX6600/stargazers)
[![Downloads](https://img.shields.io/github/downloads/ones20250/Openwrt-AX6600/total?logo=github&label=%E4%B8%8B%E8%BD%BD%E9%87%8F)](https://github.com/ones20250/Openwrt-AX6600/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/ones20250/Openwrt-AX6600/QCA-ALL.yml?label=%E7%BC%96%E8%AF%91)](https://github.com/ones20250/Openwrt-AX6600/actions)
[![Release Date](https://img.shields.io/github/release-date/ones20250/Openwrt-AX6600?label=%E6%9C%80%E6%96%B0%E5%8F%91%E5%B8%83)](https://github.com/ones20250/Openwrt-AX6600/releases)

[👉 进入项目主页](https://github.com/ones20250/Openwrt-AX6600)
---

## ⭐ 项目特点

- 🔥 **云编译构建** - 基于 GitHub Actions 完全自动化极速编译（宿主工具穿透与缓存优化）
- 📦 **官方支持** - 完美适配京东云雅典娜AX6600（RE-CS-02）
- 🐧 **全新内核** - 全面迁移至 Linux 6.18 LTS 内核与 firewall4 架构
- ⚡ **硬件加速** - Qualcomm PPE 开源硬件加速 + Linux 原生 Flowtable 硬件卸载
- 🎯 **全锥 NAT** - 原生 SONiC FullCone NAT1，游戏联机与 P2P 穿透无阻
- ❄️ **低温运行** - 移除 NSS 闭源高发热组件，待机温度显著降低 5~10℃
- 💡 **点阵屏控制** - 内置雅典娜 LED 点阵屏官方驱动与管理界面（athena-led）
- 🚀 **开箱即用** - 预装常用网络工具与自选核心插件（Docker / PassWall2 / OpenClash）
- 📶 **WiFi 稳定** - 无线驱动内存与系统水位线深度调优，7×24 高负载久跑不断流
- 🔄 **源码同步** - 自动跟进 OpenWrt/ImmortalWrt 最新上游 owrt 分支
- 🧩 **灵活定制** - 支持自定义编译配置和插件

---

## 📥 快速开始

### 1️⃣ 下载固件

| 版本 | 下载入口 | 适合场景 |
|------|----------|----------|
| 🍃 `PURE` 纯净版 | 🎯 **[👉 下载最新 PURE 固件](https://github.com/ones20250/Openwrt-AX6600/releases?q=PURE&expanded=true)** | 轻量稳定，日常推荐，插件按需自装 |
| 🚀 `PLUS` 版 | 🎯 **[👉 下载最新 PLUS 固件](https://github.com/ones20250/Openwrt-AX6600/releases?q=PLUS&expanded=true)** | OpenClash / PassWall2 / Docker / AdGuard Home 开箱即用 |

> ⭐ 固件对你有用的话，顺手点个 Star —— 这是对持续维护最好的支持！

> 💡 打开后列表**最上方**即为该版本最新固件；也可浏览 [全部 Releases](https://github.com/ones20250/Openwrt-AX6600/releases)。

📦 **刷机救砖全家桶**
👉 **[点击下载刷机文件](https://github.com/ones20250/Openwrt-AX6600/releases/tag/Router-Flashing-Files)**

> 包含：不死 U-Boot（亚瑟/雅典娜通用）、双分区 GPT 分区表、原厂还原固件、USB 9008 救砖工具、TTL 接线图、图文刷机教程

---

## 📋 固件说明

| 说明 | 详情 |
|------|------|
| **编译时间** | 显示的时间为编译开始时间，用于对应上游源码版本 |
| **版本划分** | 默认同时构建 `PURE` 纯净版与 `PLUS` 版 |
| **基础功能** | 纯净版保持当前轻量配置，包含完整网络功能栈 |
| **扩展插件** | Plus 版额外集成 OpenClash、PassWall2、Docker / Dockerman、AdGuard Home、DDNS、ttyd 终端、UPnP 等常用组件，也可通过自定义配置 `.config` 文件增加插件 |
| **硬件平台** | 基于 QUALCOMMAX（IPQ6010）架构 |
| **性能优化** | 针对 IPQ6010 平台进行网络性能调优 |

### 固件版本

| 版本 | 适合人群 | 预置内容 |
|------|----------|----------|
| `PURE` 纯净版 | 希望系统轻量、稳定，按需自行安装插件的用户 | 保持当前配置，预装基础网络与常用管理插件 |
| `PLUS` 版 | 希望刷完即用常见扩展服务的用户 | 在纯净版基础上增加 OpenClash、PassWall2、Docker / Dockerman、AdGuard Home、DDNS、ttyd 终端、UPnP，以及分区扩容（partexp）、网络唤醒（wolultra）等实用插件 |

> 💡 Releases 中的文件名会包含 `pure` 或 `plus`，请按需求下载对应版本。

### 文件命名与附件说明

Releases 页面每个版本包含以下文件（PURE 与 PLUS 分开发布，Release tag 中同样含版本字样）：

| 文件 | 说明 |
|------|------|
| `源码作者-分支-pure/plus-设备型号-时间.bin` 等 | 固件本体；文件名带 `factory` 用于从原厂固件首次刷入，带 `sysupgrade` 用于 OpenWrt/ImmortalWrt 系统内升级 |
| `Config-配置-版本-作者-分支-时间.txt` | 本次编译使用的完整 `.config`，便于复现构建或二次定制 |
| `Packages-配置-版本-作者-分支-时间.txt` | 外部插件（OpenClash / PassWall2 及依赖 feed）的仓库、分支与 commit 记录，仅 `PLUS` 版生成，便于排查上游变更 |

---

## 🛠️ 刷机指南

> [!IMPORTANT]
> ### 架构升级与系统升级注意事项
> 本次迁移全面切换至 **Qualcomm PPE 开源硬件加速** 架构，并修正了 LuCI 防火墙管理界面包名（启用内嵌于 firewall4 的 SONiC FullCone NAT1）。
> - **目标分区红线**：本次 PLUS 升级包约 160MB，升级前必须核实目标系统分区（`rootfs`）已扩容（大于 200MB，原厂 60MB 分区绝对不能刷入 PLUS 版，不能以整机 eMMC 存储容量误判）。
> - **Docker 数据保护**：`sysupgrade` 默认会重置内部 Flash 的 overlay 分区，**保留配置不等于保留整个 overlay**！若 Docker 数据位于内部 overlay，升级前必须完整导出到电脑；若位于独立分区，升级后必须先核验挂载再启动 Docker。
> - **平滑保留配置升级**：可保留现有网络、Wi-Fi、DHCP、防火墙与用户规则，升级后仅需精准清理失效的 NSS 专用节（如 `firewall.qcanssecm`），无需为了启用 PPE 而覆盖整份旧防火墙配置。
> - **跨架构新手建议**：若旧版系统配置过度杂乱或曾做过重度魔改，建议导出备份后选择不保留配置升级（`sysupgrade -n 固件文件名.bin`），待进入系统确认正常后再导入配置。

> ⚠️ **重要提示：** 以下操作涉及 U-Boot 和分区修改，**请务必先备份重要数据**，谨慎操作！

### 详细教程
- 📖 **[保留配置升级与 Docker 备份恢复指南 →](Docs/AX6600保留配置升级与Docker备份恢复指南.md)**（升级前分区体检 / Docker 数据全量备份 / 保留配置升级 / NSS 遗留项精准清理 / 验收全流程）
- 📖 **[完整刷机救砖教程 →](Docs/刷机救砖教程.md)**（开 SSH / 备份分区 / 刷 U-Boot / 9008 救砖全流程，推荐新手通读）

### 刷机前必读

1. **备份所有数据**
   ```bash
   # SSH 连接到设备
   ssh root@192.168.1.1

   # 备份整个 U-Boot 分区
   dd if=/dev/mtd0 of=/tmp/uboot.bin

   # 备份分区表
   dd if=/dev/mtd1 of=/tmp/partition_table.bin
   ```
2. **验证文件完整性**

   每个 Release 附带 `sha256sums.txt` 校验文件，将其与固件下载到同一目录后执行：
   ```bash
   # Linux / macOS
   sha256sum -c sha256sums.txt --ignore-missing
   ```
   ```powershell
   # Windows：计算固件哈希，与 sha256sums.txt 中对应行比对
   certutil -hashfile 固件文件名.bin SHA256
   ```
3. **准备恢复方案**
   - 保留 TTL 串口工具
   - 准备原厂固件备份
   - 了解救砖流程

### 刷机步骤

1. **启用 SSH 访问**
   - 进入旧版本固件管理后台
   - 启用 SSH 服务

2. **备份分区**（二选一）
   - 通过 SSH 备份分区数据
   - 或使用 TTL 串口备份（更安全）

3. **刷入 U-Boot**
   - 安装不死 U-Boot（防砖）
   - 更新双分区 GPT 分区表

4. **创建存储分区**
   - 新建 storage 分区
   - 恢复跑分分区数据

5. **刷入固件**
   - 从 Releases 下载最新固件（首刷选 `factory`，升级选 `sysupgrade`）
   - 通过 U-Boot Web 界面刷入

### U-Boot 固件仓库

| 平台 | 仓库地址 | 说明 |
|------|---------|------|
| **eMMC 版本** | [chenxin527/uboot-ipq60xx-emmc-build](https://github.com/chenxin527/uboot-ipq60xx-emmc-build) | eMMC 存储设备专用 |
| **NOR Flash 版本** | [chenxin527/uboot-ipq60xx-nor-build](https://github.com/chenxin527/uboot-ipq60xx-nor-build) | NOR Flash 存储设备专用 |

> 💡 **提示：** U-Boot 版本选择需与您的设备硬件配置相匹配，错误选择会导致设备无法启动！

### 常见风险及预防

| 风险 | 症状 | 预防方法 |
|------|------|---------|
| **U-Boot 错误** | 设备无法启动 | 使用不死 U-Boot，备份原件 |
| **分区错误** | 系统无法识别 | 使用正确的 GPT 分区表 |
| **断电** | 刷机中断 | 使用 UPS 或稳定电源 |
| **固件损坏** | 开机无响应 | 验证 SHA256 后再刷入 |

### WiFi 推荐设置（刷机后调优）

雅典娜为三频机型，共三个 WiFi：2.4G（2×2，574Mbps）、5.2GHz 游戏频段 5G-1（4×4，4804Mbps）、5.8GHz 影音频段 5G-2（2×2，1201Mbps），信道和带宽按各自频段分别设置：

| WiFi | 信道 | 带宽 | 说明 |
|------|------|------|------|
| 2.4G（2×2） | `11` | `20MHz` | 抗干扰优先，拥挤环境下 20MHz 更稳 |
| 5G-1 游戏频段（4×4） | `44` | `160MHz` | 4×4 满血跑 160MHz 可达 4804Mbps；若无法开启或断流，回退 `80MHz` |
| 5G-2 影音频段（2×2） | `149` | `80MHz` | `149` 起在 US 下功率上限最高，非 DFS 无雷达断流 |

三个 WiFi 通用的设置：

| 项 | 推荐值 | 说明 |
|----|--------|------|
| 地区 | `US` | 可用信道多、功率上限高，推荐信道在 US 下均为非 DFS |
| 发射功率 | `24 dBm` | US 法规内的高功率档 |
| 加密 | `WPA2-PSK`，算法 `CCMP` | 兼容性最稳组合，老设备无障碍接入 |

---

## 🧱 构建机制（PURE / PLUS 如何隔离）

- 两个版本由工作流参数 `WRT_PROFILE` 区分，所有 Plus 版逻辑（额外配置、feed、插件克隆）均由该条件隔离，**纯净版产物不受 Plus 版任何改动影响**。
- Plus 版插件来源唯一：LuCI 插件本体由 `Scripts/Packages.sh` 克隆到 `package/`（优先级高于 feeds），依赖包（xray、sing-box 等）由 `passwall_packages` feed 提供，避免同名包双重定义。
- Plus 版配置 `Config/GENERAL_AX6600_PLUS.txt` 追加在通用配置之后，按 kconfig 规则覆盖纯净版关闭的选项（如 Docker 所需内核模块、`dnsmasq-full`）。
- 编译缓存（ccache / 工具链）与版本无关，PURE 与 PLUS 共享同一份，不额外占用缓存配额。

### 版本与验证建议

- `PURE`：推荐作为日常稳定版，保持当前轻量配置。
- `PLUS`：Plus 版会额外集成 OpenClash、PassWall2、Docker / Dockerman、AdGuard Home、DDNS、ttyd、UPnP 等，固件体积和运行资源占用都会明显高于纯净版。
- 手动测试时可在 `WRT-TEST` 工作流选择 `PROFILE=PURE` 或 `PROFILE=PLUS`；建议 Plus 版发布前至少先用 `TEST=true` 生成最终 `.config`，再用完整编译确认上游插件依赖没有变化。
- Release 会额外上传 `Packages-*.txt` 记录 Plus 版外部插件仓库、分支和 commit，方便排查 OpenClash / PassWall2 上游变更导致的编译问题。

> ⚠️ Plus 版依赖外部插件仓库和上游 feeds，若上游调整包名或依赖，可能需要同步更新 `Config/GENERAL_AX6600_PLUS.txt`。

### PLUS 版使用提示

- **AdGuard Home 首次启用**：出厂默认关闭。启用服务后访问 `http://路由器IP:3000` 完成安装向导，向导中 **DNS 监听端口请填 `5553`**（`53` 已被系统 dnsmasq 占用，填 53 会报错）；完成后在 LuCI「网络 → DHCP/DNS」的「DNS 转发」中填入 `127.0.0.1#5553` 并勾选「忽略解析文件」，广告过滤即对全局生效。
- **代理插件二选一**：OpenClash 与 PassWall2 工作机制相同（接管 DNS + 透明代理规则），同时启用会互相抢占，轻则其中一个失效、分流错乱，重则断网，请只启用其中一个，切换前先停用当前插件。
- **Docker 存储去向**：Docker 数据默认写入系统分区，容易撑爆。建议先用「分区扩容（partexp）」将空闲 eMMC 挂载为独立分区，再在 Docker 设置中把存储路径指向该分区。

## 📂 项目结构

| 目录/文件 | 用途 | 说明 |
|----------|------|------|
| `.github/workflows/` | CI/CD 自动编译 | 定义 GitHub Actions 工作流，实现云端自动构建 |
| `Scripts/` | 编译脚本 | 包含插件拉取、自定义设置等辅助脚本 |
| `Config/` | 编译配置 | 存放 OpenWrt `.config` 配置文件（含 `GENERAL_AX6600_PLUS.txt` Plus 版增量配置） |
| `Docs/` | 文档 | 刷机救砖教程等图文文档 |

---

## 🔗 上游源码与依赖

| 版本 | 仓库地址 | 说明 |
|------|---------|------|
| **官方版** | [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt.git) | ImmortalWrt 官方仓库 |
| **高通专用版** | [ones20250/immortalwrt_ipq](https://github.com/ones20250/immortalwrt_ipq.git) | IPQ 平台优化版本，定期同步上游并验证后构建 |

---

## 🚀 自定义编译

### 修改编译配置

| 配置文件 | 作用范围 |
|----------|----------|
| `Config/GENERAL_AX6600.txt` | 通用配置，PURE / PLUS 两个版本共用 |
| `Config/GENERAL_AX6600_PLUS.txt` | Plus 版增量配置，仅 PLUS 生效 |
| `Config/IPQ60XX-WIFI-YES.txt` | 设备与平台基础配置 |

### 触发编译

编译不会随代码提交自动触发，需通过以下方式之一：

- **手动全量编译**：Actions → `QCA-ALL` → Run workflow，同时构建 PURE 与 PLUS 两个版本。
- **配置验证**：Actions → `WRT-TEST`，可选择 `PROFILE` 并勾选 `TEST=true`，仅生成最终 `.config` 不编译固件，几分钟出结果。
- **每日自动编译**：每天早上 6 点（北京时间）由 `Auto-Clean` 清理旧产物后自动触发。

---

## 📊 固件特性对比

| 特性 | 原厂固件 | 本项目固件 |
|------|---------|----------|
| **OpenWrt 版本** | 不支持 | ✅ Linux 6.18 LTS / firewall4 |
| **硬件加速** | ⚠️ 原厂闭源 NSS 架构 | ✅ Qualcomm PPE 开源硬件加速 + Flowtable 硬件卸载（免除 NSS 闭源微码常驻开销） |
| **NAT 模式** | 普通锥型 NAT | ✅ 原生 SONiC FullCone NAT1（集成于 firewall4） |
| **网络性能** | 基础 | ✅ 千兆 / 2.5G 双工硬件流表卸载（支持常见单向/双向流卸载） |
| **自定义插件** | ❌ 不支持 | ✅ 完全支持（Docker / PassWall2 / OpenClash 开箱即用） |
| **构建速度** | ❌ 慢 | ✅ CI 宿主工具穿透与预编译优化（跳过 Go/Rust 引导工具链源码编译） |
| **定期更新** | ❌ 不定期 | ✅ 自动跟进上游 owrt 分支云编译 |
| **开源透明** | ❌ 闭源 | ✅ 全开源公开 |

---

## ⚠️ 免责声明

刷机有风险，操作需谨慎。

本项目固件仅供学习与研究使用，请确认设备型号匹配并提前备份数据。
因刷机造成的设备损坏或数据丢失，作者不承担任何责任。
