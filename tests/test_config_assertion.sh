#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regression Test: Verify CI intent-aware dynamic assertion logic for PLUS plugins
# Ensures official releases guard against silent drops while allowing fork customization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/WRT-CORE.yml"

BASH_BIN="${BASH:-}"
if [ -z "$BASH_BIN" ] || ! "$BASH_BIN" -c "true" 2>/dev/null; then
    if command -v bash >/dev/null 2>&1 && bash -c "true" 2>/dev/null; then
        BASH_BIN="bash"
    elif [ -x "/bin/bash" ]; then
        BASH_BIN="/bin/bash"
    elif [ -x "/usr/bin/bash" ]; then
        BASH_BIN="/usr/bin/bash"
    elif [ -x "C:/Program Files/Git/bin/bash.exe" ]; then
        BASH_BIN="C:/Program Files/Git/bin/bash.exe"
    else
        BASH_BIN="sh"
    fi
fi

echo "=== Running CI Intent-Aware Dynamic Assertion Regression Test ==="

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "ERROR: Workflow file not found at $WORKFLOW_FILE" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'ci_assert_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

# 从 WRT-CORE.yml 中提取断言块逻辑
ASSERT_SNIPPET="$(awk '/# 5\. PLUS 核心插件入选断言/{flag=1; next} flag && /if \[\[.*FAIL/{flag=0} flag' "$WORKFLOW_FILE")"
if [ -z "$ASSERT_SNIPPET" ]; then
    echo "FAIL: Failed to extract PLUS assertion block from $WORKFLOW_FILE!" >&2
    exit 1
fi

TEST_SCRIPT="$TMP_DIR/run_assert.sh"
cat << 'EOF' > "$TEST_SCRIPT"
#!/usr/bin/env bash
set -e
CONFIG_FILE="$1"
WRT_PROFILE="$2"
FAIL=0

cd "$(dirname "$CONFIG_FILE")"
EOF

echo "$ASSERT_SNIPPET" >> "$TEST_SCRIPT"

cat << 'EOF' >> "$TEST_SCRIPT"
if [[ $FAIL -ne 0 ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "$TEST_SCRIPT"

run_case() {
    local CASE_NAME="$1"
    local SEED_DATA="$2"
    local CONFIG_DATA="$3"
    local EXPECT_EXIT="$4"

    echo "--- Case: $CASE_NAME ---"
    rm -f "$TMP_DIR/.config.seed" "$TMP_DIR/.config"

    if [ "$SEED_DATA" != "NONE" ]; then
        printf "%s\n" "$SEED_DATA" > "$TMP_DIR/.config.seed"
    fi
    printf "%s\n" "$CONFIG_DATA" > "$TMP_DIR/.config"

    set +e
    "$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
    local ACTUAL_EXIT=$?
    set -e

    if [ "$ACTUAL_EXIT" -ne "$EXPECT_EXIT" ]; then
        echo "FAIL: $CASE_NAME expected exit code $EXPECT_EXIT, but got $ACTUAL_EXIT" >&2
        cat "$TMP_DIR/output.log" >&2
        exit 1
    fi
    echo "PASS: $CASE_NAME (exit code $ACTUAL_EXIT as expected)."
}

# 1. 官方全量 PLUS 构建：5 个核心插件均声明且入选
run_case "Official PLUS full packages present" \
    "CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" \
    "CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 0

# 2. Issue #29 场景：用户紧贴注释 passwall2
run_case "User commented out passwall2 (#CONFIG_PACKAGE_...)" \
    "#CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" \
    "CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 0

# 3. 标准 Kconfig 禁用：# CONFIG_PACKAGE_... is not set
run_case "User disabled passwall2 via standard is not set" \
    "# CONFIG_PACKAGE_luci-app-passwall2 is not set
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" \
    "CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 0

# 4. 私有配置覆盖：先开启后追加 =n
run_case "User overridden passwall2=n at the end of seed" \
    "CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y
CONFIG_PACKAGE_luci-app-passwall2=n" \
    "CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 0

# 5. 故障注入：声明启用 passwall2 但被 defconfig 静默丢弃
run_case "Silent drop detection (declared =y but missing from .config)" \
    "CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" \
    "CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 1

# 6. 单文件兼容性：无 .config.seed 时默认必须全部在场
run_case "Compatibility: missing seed file strictly requires all packages" \
    "NONE" \
    "CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y" 0

# 7. 真实构建环境缺失 PPE 驱动检测：在 target 存在时严格拦截驱动缺失
echo "--- Case: Target tree present but Qualcomm PPE driver missing ---"
mkdir -p "$TMP_DIR/target"
printf "CONFIG_PACKAGE_luci-app-passwall2=y\nCONFIG_PACKAGE_luci-app-openclash=y\nCONFIG_PACKAGE_luci-app-dockerman=y\nCONFIG_PACKAGE_luci-app-adguardhome=y\nCONFIG_PACKAGE_luci-app-wolultra=y\n" > "$TMP_DIR/.config"
printf "CONFIG_PACKAGE_luci-app-passwall2=y\nCONFIG_PACKAGE_luci-app-openclash=y\nCONFIG_PACKAGE_luci-app-dockerman=y\nCONFIG_PACKAGE_luci-app-adguardhome=y\nCONFIG_PACKAGE_luci-app-wolultra=y\n" > "$TMP_DIR/.config.seed"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: Target tree missing PPE driver expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE 驱动文件缺失" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report missing PPE driver: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Target tree missing PPE driver strictly failed (exit code 1)."

# 8. 真实构建环境 PPE 驱动未植入时钟修复检测：严格拦截
echo "--- Case: Target tree PPE driver missing clock fix logic ---"
mkdir -p "$TMP_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm"
echo "void qca_ppe_dummy(void) {}" > "$TMP_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: PPE driver without clock fix expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "未成功植入 QCA8081 时钟修复逻辑" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report unpatched clock fix: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Target tree PPE driver without clock fix strictly failed (exit code 1)."

# 8b. 真实构建环境 IPQ6018 时钟补丁缺失或为空检测：严格拦截
echo "--- Case: Target tree IPQ6018 clock patch missing or empty ---"
echo "int ppe_port_clk_parents(void *priv) { return 0; }" > "$TMP_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c"
mkdir -p "$TMP_DIR/target/linux/qualcommax/patches-6.18"
rm -f "$TMP_DIR/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: Missing IPQ6018 patch expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "IPQ6018 GCC 时钟补丁缺失或为空" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report missing IPQ6018 patch: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Target tree missing IPQ6018 patch strictly failed (exit code 1)."

# 8c. 真实构建环境 IPQ8074 冲突补丁残留检测：严格拦截
echo "--- Case: Target tree IPQ8074 conflict patch present ---"
echo "patch content" > "$TMP_DIR/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
echo "conflict patch content" > "$TMP_DIR/target/linux/qualcommax/patches-6.18/0919-clk-qcom-gcc-ipq8074-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: IPQ8074 conflict patch expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "检测到已废弃的 IPQ8074 冲突补丁残留" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report IPQ8074 conflict patch: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Target tree with IPQ8074 conflict patch strictly failed (exit code 1)."

# 9. 真实构建环境 PPE 驱动与 IPQ6018 补丁完整生效通过校验
echo "--- Case: Target tree PPE driver and IPQ6018 patch present ---"
rm -f "$TMP_DIR/target/linux/qualcommax/patches-6.18/0919-clk-qcom-gcc-ipq8074-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 0 ]; then
    echo "FAIL: PPE driver and patch with clock fix expected exit 0, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE QCA8081 时钟修复逻辑与分频补丁校验通过" "$TMP_DIR/output.log"; then
    echo "FAIL: Success message not found: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Target tree PPE driver with clock fix succeeded (exit code 0)."

# 10. PURE 模式下真实构建环境缺失 PPE 驱动检测：严格拦截（确保断言不因 Profile 隔离失效）
echo "--- Case: PURE profile target tree missing Qualcomm PPE driver ---"
rm -f "$TMP_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PURE" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: PURE profile missing PPE driver expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE 驱动文件缺失" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report missing PPE driver under PURE: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: PURE profile target tree missing PPE driver strictly failed (exit code 1)."

# 11. PURE 模式下真实构建环境 PPE 驱动与 IPQ6018 补丁完整生效通过校验
echo "--- Case: PURE profile target tree PPE driver with clock fix present ---"
echo "int ppe_port_clk_parents(void *priv) { return 0; }" > "$TMP_DIR/target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c"
set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PURE" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 0 ]; then
    echo "FAIL: PURE profile PPE driver with clock fix expected exit 0, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE QCA8081 时钟修复逻辑与分频补丁校验通过" "$TMP_DIR/output.log"; then
    echo "FAIL: Success message not found under PURE: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: PURE profile target tree PPE driver with clock fix succeeded (exit code 0)."
rm -rf "$TMP_DIR/target"

# -----------------------------------------------------------------------------
# 12. 校验 firewall4 与雅典娜目标设备架构断言逻辑
# -----------------------------------------------------------------------------
echo "--- Case: Verify firewall4 and Athena target device assertion extraction ---"
FIREWALL_ASSERT_SNIPPET="$(awk '/# 4\. 检查 PPE 硬件流表/{flag=1; next} flag && /# 5\. PLUS/{flag=0} flag' "$WORKFLOW_FILE")"
if [ -z "$FIREWALL_ASSERT_SNIPPET" ]; then
    echo "FAIL: Failed to extract firewall4 / target device assertion block from $WORKFLOW_FILE!" >&2
    exit 1
fi

FW_TEST_SCRIPT="$TMP_DIR/run_fw_assert.sh"
cat << 'EOF' > "$FW_TEST_SCRIPT"
#!/usr/bin/env bash
set -e
CONFIG_FILE="$1"
FAIL=0
cd "$(dirname "$CONFIG_FILE")"
EOF
echo "$FIREWALL_ASSERT_SNIPPET" >> "$FW_TEST_SCRIPT"
cat << 'EOF' >> "$FW_TEST_SCRIPT"
if [[ $FAIL -ne 0 ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "$FW_TEST_SCRIPT"

# 12a. 全量合法配置：PPE offload, luci-app-firewall, firewall4, jdcloud_re-cs-02 均在场
cat << 'EOF' > "$TMP_DIR/.config"
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_firewall4=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y
EOF
set +e
"$BASH_BIN" "$FW_TEST_SCRIPT" "$TMP_DIR/.config" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 0 ]; then
    echo "FAIL: Valid firewall4 and target device config expected exit 0, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
echo "PASS: Valid firewall4 and target device assertions passed."

# 12b. 故障注入：缺少 CONFIG_PACKAGE_firewall4=y 时必须被拦截阻断
cat << 'EOF' > "$TMP_DIR/.config"
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y
EOF
set +e
"$BASH_BIN" "$FW_TEST_SCRIPT" "$TMP_DIR/.config" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: Missing firewall4 expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "CONFIG_PACKAGE_firewall4 未入选" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report missing firewall4: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Missing firewall4 assertion correctly triggered (exit code 1)."

# 12c. 故障注入：缺少目标机型 CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y 时必须被拦截阻断
cat << 'EOF' > "$TMP_DIR/.config"
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_firewall4=y
EOF
set +e
"$BASH_BIN" "$FW_TEST_SCRIPT" "$TMP_DIR/.config" > "$TMP_DIR/output.log" 2>&1
ACTUAL_EXIT=$?
set -e
if [ "$ACTUAL_EXIT" -ne 1 ]; then
    echo "FAIL: Missing target device expected exit 1, but got $ACTUAL_EXIT" >&2
    cat "$TMP_DIR/output.log" >&2
    exit 1
fi
if ! grep -q "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02 未入选" "$TMP_DIR/output.log"; then
    echo "FAIL: Error message did not report missing target device: $(cat "$TMP_DIR/output.log")" >&2
    exit 1
fi
echo "PASS: Missing target device assertion correctly triggered (exit code 1)."

# -----------------------------------------------------------------------------
# 13. Actions 工作流权限收缩至最小权限验证 (杜绝 write-all 高危权限)
# -----------------------------------------------------------------------------
echo "--- Case: Verify Actions workflow permissions minimization ---"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
if grep -rn "permissions:[[:space:]]*write-all" "$WORKFLOW_DIR"; then
    echo "FAIL: Found leftover 'permissions: write-all' in workflows!" >&2
    exit 1
fi

for WF in "$WORKFLOW_DIR"/*.yml; do
    if ! grep -q "permissions:" "$WF"; then
        echo "FAIL: Workflow $WF missing explicit 'permissions:' specification!" >&2
        exit 1
    fi
done
echo "PASS: All Actions workflows strictly minimized (0 instances of write-all)."

echo "================================================================================"
echo "=== All Intent-Aware Dynamic Assertion & Security Regression Tests Passed! ==="
echo "================================================================================"
