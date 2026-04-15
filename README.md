# 🚀 OpenWrt AX6600 / IPQ60xx Router Firmware Cloud Build (NSS Accelerated)
OpenWrt / AX6600 / JDCloud RE-CS-02 / IPQ6010 / NSS acceleration / firmware / router / cloud build

[👉 进入项目主页](https://github.com/ones20250/Openwrt-AX6600) 适配京东云雅典娜 AX6600（JDCloud RE-CS-02）

一个基于 GitHub Actions 的 OpenWrt 自动编译项目，支持 QUALCOMMAX（IPQ6010）设备。

---

## ⭐ 项目特点

- 🔥 OpenWrt 云编译（GitHub Actions 自动构建）
- 📦 适配京东云雅典娜 AX6600（RE-CS-02）
- 🚀 预装常用网络插件
- ⚡ 支持 NSS 硬件加速（性能优化）
- 🌐 提升 NAT / 转发 / 吞吐性能
- 🔄 自动同步上游 OpenWrt / ImmortalWrt 源码
- 🧩 支持自定义编译配置

---

## 📦 固件下载
🚀 [👉 最新固件下载（Releases）](https://github.com/ones20250/Openwrt-AX6600/releases/latest)  

---

## 🛠️ 刷机教程

👉 完整刷机图文教程（推荐新手参考） [点击查看教程](https://blog.waynecommand.com/post/athena-re-cs-02.html)


1. 旧版本固件开启 SSH  
2. 备份分区（SSH 备份 / TTL 备份）  
3. 刷入不死 U-Boot 和双分区 GPT 分区表  
4. 新建 storage 分区并还原跑分分区
5. Releases刷入最新固件 

⚠️ 操作存在风险，请确保了解步骤后再执行！

---

## 🧠 固件说明

- 固件时间 = 编译开始时间（用于核对上游源码版本）
- 默认包含基础网络功能
- 可通过自定义配置增加插件
- 基于 QUALCOMMAX（IPQ6010）平台
- 针对 IPQ6010 平台进行网络性能优化

---

## ⚙️ 项目结构

- `workflows` —— 自定义 CI 配置
- `Scripts` —— 自定义脚本
- `Config` —— 自定义编译配置

---

## 🔗 上游源码

**官方版：**  
https://github.com/immortalwrt/immortalwrt.git  

**高通版：**  
https://github.com/ones20250/immortalwrt_ipq.git  

---

## 🔧 U-Boot

**高通版：**

- https://github.com/chenxin527/uboot-ipq60xx-emmc-build  
- https://github.com/chenxin527/uboot-ipq60xx-nor-build  

---


## ⭐ 如果这个项目对你有帮助，欢迎 Star！
