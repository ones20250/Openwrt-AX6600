# QCA8081 端口时钟与 GCC 分频原生内置说明

京东云无线宝雅典娜 AX6600（IPQ6010 / IPQ6018）搭载的 QCA8081 2.5G 物理网口，需要以下两项核心时钟修复以杜绝出方向大量 CRC 丢包与速率衰减至 900M 的硬件级缺陷：

1. **PPE 端口父时钟绑定**：在设置端口速率前，显式将每个 PPE 端口的 RX/TX 时钟父级指向其 PCS 节点（UNIPHY）的 RX/TX 输出，纠正 U-Boot 遗留将 Port 5 TX 挂在 RX 恢复时钟上的严重抖动缺陷。
2. **IPQ6018 SGMII 频率表对齐**：在 `gcc-ipq6018` 驱动中补齐 UNIPHY1 在 125MHz（/1）与 25MHz（/5）下的分频配置，确保 1000M 与 100M 速率自协商时不脱离 UNIPHY1。
3. **单一硬件排他性原则**：严格排除与雅典娜无关的 IPQ8074 芯片冲突补丁，避免多芯片抽象带来的内核源码上下文冲突与构建中断。

### 上游原生内置状态与工程处置

- **原生合入**：上游官方 OpenWrt qualcommax 目标分支已正式原生合并等价驱动逻辑（`qca_ppe_main.c` 中的 `ppe_port_clk_parents`）以及官方时钟补丁（`target/linux/qualcommax/patches-6.18/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch`）。
- **外挂代码退役**：本地外挂补丁 `Patches/qualcommax-qca8081-clock-fix.patch` 与外挂准备脚本 `.github/scripts/prepare-qca8081-clock-fix.sh` 现已正式退役移除。
- **CI 原生完备性门禁**：构建工作流 `.github/workflows/WRT-CORE.yml` 在配置断言步骤中内置原生完备性门禁，持续严格核验上游驱动与官方 0084 补丁状态，阻断任何驱动回退或冲突补丁残留。
