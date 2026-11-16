#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regression Test: Verify QCA8081 Native Clock Fix Assertion Gates & Workflow Cleanliness
# Ensures upstream native PPE driver logic and IPQ6018 clock patches are strictly enforced
# while guaranteeing that obsolete out-of-tree patches and helper scripts remain retired.

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

echo "=== Running QCA8081 Native Clock Fix Assertion & Regression Tests ==="

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "ERROR: Workflow file not found at $WORKFLOW_FILE" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'qca_assert_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

# -----------------------------------------------------------------------------
# 提取 WRT-CORE.yml 中的第 6 项 Qualcomm PPE QCA8081 时钟驱动原生完备性断言块
# -----------------------------------------------------------------------------
ASSERT_SNIPPET="$(awk '/# 6\. Qualcomm PPE 时钟驱动.*断言/{flag=1; next} flag && /rm -f \.config\.seed/{flag=0} flag' "$WORKFLOW_FILE")"
if [ -z "$ASSERT_SNIPPET" ]; then
    echo "FAIL: Failed to extract QCA8081 assertion block from $WORKFLOW_FILE!" >&2
    exit 1
fi

TEST_SCRIPT="$TMP_DIR/run_qca_assert.sh"
cat << 'EOF' > "$TEST_SCRIPT"
#!/usr/bin/env bash
set -e
FAIL=0
TARGET_ROOT="$1"
cd "$TARGET_ROOT"
EOF

echo "$ASSERT_SNIPPET" >> "$TEST_SCRIPT"

cat << 'EOF' >> "$TEST_SCRIPT"
if [[ $FAIL -ne 0 ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "$TEST_SCRIPT"

# -----------------------------------------------------------------------------
# 辅助函数：初始化测试用的源码树结构
# -----------------------------------------------------------------------------
PPE_REL_DIR="target/linux/qualcommax/files/drivers/net/ethernet/qualcomm"
PATCH_REL_DIR="target/linux/qualcommax/patches-6.18"

setup_tree() {
    local TREE="$1"
    rm -rf "$TREE"
    mkdir -p "$TREE/$PPE_REL_DIR"
    mkdir -p "$TREE/$PATCH_REL_DIR"
}

# -----------------------------------------------------------------------------
# Test 1: 上游正常集成通过 (Upstream Native Integration Passed)
# -----------------------------------------------------------------------------
echo "--- Test 1a: Upstream native integration with official 0084 patch succeeds ---"
TREE_1A="$TMP_DIR/tree_1a"
setup_tree "$TREE_1A"
cat << 'EOF' > "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c"
static int ppe_port_clk_parents(struct qca_ppe_priv *priv) {
    /* Upstream native QCA8081 clock parent binding */
    return 0;
}
EOF
cat << 'EOF' > "$TREE_1A/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch"
--- a/drivers/clk/qcom/gcc-ipq6018.c
+++ b/drivers/clk/qcom/gcc-ipq6018.c
@@ -513,6 +513,7 @@
 	C(P_UNIPHY1_RX, 2.5, 0, 0),
+	C(P_UNIPHY1_RX, 1, 0, 0),
 	C(P_UNIPHY0_RX, 1, 0, 0),
EOF

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_1A" > "$TMP_DIR/test1a.log" 2>&1
EXIT_1A=$?
set -e
if [ "$EXIT_1A" -ne 0 ]; then
    echo "FAIL: Expected exit 0 for upstream native 0084 integration, got $EXIT_1A" >&2
    cat "$TMP_DIR/test1a.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE QCA8081 时钟修复逻辑与分频补丁校验通过" "$TMP_DIR/test1a.log"; then
    echo "FAIL: Missing success verification message: $(cat "$TMP_DIR/test1a.log")" >&2
    exit 1
fi
echo "PASS: Upstream native fix with official 0084 patch recognized and passed cleanly."

echo "--- Test 1b: Upstream native integration with generic patch name matching C(P_UNIPHY1_RX, 1, 0, 0) ---"
TREE_1B="$TMP_DIR/tree_1b"
setup_tree "$TREE_1B"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_1B/$PPE_REL_DIR/qca_ppe_main.c"
cat << 'EOF' > "$TREE_1B/$PATCH_REL_DIR/custom-clk-gcc.patch"
+	C(P_UNIPHY1_RX, 1, 0, 0),
EOF

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_1B" > "$TMP_DIR/test1b.log" 2>&1
EXIT_1B=$?
set -e
if [ "$EXIT_1B" -ne 0 ]; then
    echo "FAIL: Expected exit 0 for generic patch frequency table match, got $EXIT_1B" >&2
    cat "$TMP_DIR/test1b.log" >&2
    exit 1
fi
echo "PASS: Generic patch containing C(P_UNIPHY1_RX, 1, 0, 0) correctly recognized and passed."

echo "--- Test 1c: Backward-compatible support for legacy 0918 patch filename with clock fix ---"
TREE_1C="$TMP_DIR/tree_1c"
setup_tree "$TREE_1C"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_1C/$PPE_REL_DIR/qca_ppe_main.c"
cat << 'EOF' > "$TREE_1C/$PATCH_REL_DIR/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
--- a/drivers/clk/qcom/gcc-ipq6018.c
+++ b/drivers/clk/qcom/gcc-ipq6018.c
@@ -513,6 +513,7 @@
 	C(P_UNIPHY1_RX, 2.5, 0, 0),
+	C(P_UNIPHY1_RX, 1, 0, 0),
 	C(P_UNIPHY0_RX, 1, 0, 0),
EOF

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_1C" > "$TMP_DIR/test1c.log" 2>&1
EXIT_1C=$?
set -e
if [ "$EXIT_1C" -ne 0 ]; then
    echo "FAIL: Expected exit 0 for backward-compatible 0918 patch, got $EXIT_1C" >&2
    cat "$TMP_DIR/test1c.log" >&2
    exit 1
fi
echo "PASS: Legacy 0918 patch filename backward compatibility verified."

# -----------------------------------------------------------------------------
# Test 2: 驱动缺失或时钟修复逻辑缺失拦截 (Driver Missing / Unpatched Blocked)
# -----------------------------------------------------------------------------
echo "--- Test 2a: Target tree missing Qualcomm PPE driver strictly blocked ---"
TREE_2A="$TMP_DIR/tree_2a"
setup_tree "$TREE_2A"
# 不创建 qca_ppe_main.c
cp "$TREE_1A/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch" "$TREE_2A/$PATCH_REL_DIR/"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_2A" > "$TMP_DIR/test2a.log" 2>&1
EXIT_2A=$?
set -e
if [ "$EXIT_2A" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for missing PPE driver, got $EXIT_2A" >&2
    cat "$TMP_DIR/test2a.log" >&2
    exit 1
fi
if ! grep -q "Qualcomm PPE 驱动文件缺失" "$TMP_DIR/test2a.log"; then
    echo "FAIL: Error message did not report missing PPE driver: $(cat "$TMP_DIR/test2a.log")" >&2
    exit 1
fi
echo "PASS: Missing Qualcomm PPE driver strictly blocked (exit code 1)."

echo "--- Test 2b: PPE driver missing ppe_port_clk_parents logic strictly blocked ---"
TREE_2B="$TMP_DIR/tree_2b"
setup_tree "$TREE_2B"
echo "void qca_ppe_unpatched(void) {}" > "$TREE_2B/$PPE_REL_DIR/qca_ppe_main.c"
cp "$TREE_1A/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch" "$TREE_2B/$PATCH_REL_DIR/"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_2B" > "$TMP_DIR/test2b.log" 2>&1
EXIT_2B=$?
set -e
if [ "$EXIT_2B" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for unpatched PPE driver, got $EXIT_2B" >&2
    cat "$TMP_DIR/test2b.log" >&2
    exit 1
fi
if ! grep -q "未成功植入 QCA8081 时钟修复逻辑" "$TMP_DIR/test2b.log"; then
    echo "FAIL: Error message did not report unpatched clock logic: $(cat "$TMP_DIR/test2b.log")" >&2
    exit 1
fi
echo "PASS: Unpatched PPE driver strictly blocked (exit code 1)."

# -----------------------------------------------------------------------------
# Test 3: 补丁缺失拦截 (Clock Frequency Patch Missing Blocked)
# -----------------------------------------------------------------------------
echo "--- Test 3a: Target tree missing both 0084/0918 and frequency table strictly blocked ---"
TREE_3A="$TMP_DIR/tree_3a"
setup_tree "$TREE_3A"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_3A/$PPE_REL_DIR/qca_ppe_main.c"
# patches-6.18 目录下无任何补丁文件

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_3A" > "$TMP_DIR/test3a.log" 2>&1
EXIT_3A=$?
set -e
if [ "$EXIT_3A" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for missing clock patch, got $EXIT_3A" >&2
    cat "$TMP_DIR/test3a.log" >&2
    exit 1
fi
if ! grep -q "IPQ6018 GCC 时钟补丁缺失或为空" "$TMP_DIR/test3a.log"; then
    echo "FAIL: Error message did not report missing IPQ6018 patch: $(cat "$TMP_DIR/test3a.log")" >&2
    exit 1
fi
echo "PASS: Missing IPQ6018 clock patch strictly blocked (exit code 1)."

echo "--- Test 3b: Empty (0-byte) 0084 clock patch strictly blocked ---"
TREE_3B="$TMP_DIR/tree_3b"
setup_tree "$TREE_3B"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_3B/$PPE_REL_DIR/qca_ppe_main.c"
touch "$TREE_3B/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_3B" > "$TMP_DIR/test3b.log" 2>&1
EXIT_3B=$?
set -e
if [ "$EXIT_3B" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for 0-byte clock patch, got $EXIT_3B" >&2
    cat "$TMP_DIR/test3b.log" >&2
    exit 1
fi
echo "PASS: Empty 0-byte clock patch strictly blocked (exit code 1)."

echo "--- Test 3c: Non-empty 0084 clock patch missing frequency fix strictly blocked ---"
TREE_3C="$TMP_DIR/tree_3c"
setup_tree "$TREE_3C"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_3C/$PPE_REL_DIR/qca_ppe_main.c"
echo "corrupted patch content without the required rate table" > "$TREE_3C/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_3C" > "$TMP_DIR/test3c.log" 2>&1
EXIT_3C=$?
set -e
if [ "$EXIT_3C" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for corrupted 0084 clock patch, got $EXIT_3C" >&2
    cat "$TMP_DIR/test3c.log" >&2
    exit 1
fi
if ! grep -q "IPQ6018 GCC 时钟补丁缺失或为空" "$TMP_DIR/test3c.log"; then
    echo "FAIL: Error message did not report missing IPQ6018 patch: $(cat "$TMP_DIR/test3c.log")" >&2
    exit 1
fi
echo "PASS: Non-empty 0084 clock patch missing frequency fix strictly blocked (exit code 1)."

echo "--- Test 3d: Corrupted generic patch missing frequency fix strictly blocked ---"
TREE_3D="$TMP_DIR/tree_3d"
setup_tree "$TREE_3D"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_3D/$PPE_REL_DIR/qca_ppe_main.c"
echo "custom patch without frequency rate" > "$TREE_3D/$PATCH_REL_DIR/custom-clk-gcc.patch"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_3D" > "$TMP_DIR/test3d.log" 2>&1
EXIT_3D=$?
set -e
if [ "$EXIT_3D" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for corrupted generic clock patch, got $EXIT_3D" >&2
    cat "$TMP_DIR/test3d.log" >&2
    exit 1
fi
if ! grep -q "IPQ6018 GCC 时钟补丁缺失或为空" "$TMP_DIR/test3d.log"; then
    echo "FAIL: Error message did not report missing IPQ6018 patch: $(cat "$TMP_DIR/test3d.log")" >&2
    exit 1
fi
echo "PASS: Corrupted generic clock patch missing frequency fix strictly blocked (exit code 1)."

# -----------------------------------------------------------------------------
# Test 4: 冲突补丁残留拦截 (IPQ8074 Conflict Patch Blocked)
# -----------------------------------------------------------------------------
echo "--- Test 4: Obsolete IPQ8074 conflict patch residual strictly blocked ---"
TREE_4="$TMP_DIR/tree_4"
setup_tree "$TREE_4"
cp "$TREE_1A/$PPE_REL_DIR/qca_ppe_main.c" "$TREE_4/$PPE_REL_DIR/qca_ppe_main.c"
cp "$TREE_1A/$PATCH_REL_DIR/0084-clk-qcom-gcc-ipq6018-add-port5-sgmii-rates.patch" "$TREE_4/$PATCH_REL_DIR/"
echo "conflict" > "$TREE_4/$PATCH_REL_DIR/0919-clk-qcom-gcc-ipq8074-keep-port-5-on-uniphy1-at-SGMII-rates.patch"

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TREE_4" > "$TMP_DIR/test4.log" 2>&1
EXIT_4=$?
set -e
if [ "$EXIT_4" -ne 1 ]; then
    echo "FAIL: Expected exit 1 for IPQ8074 conflict patch, got $EXIT_4" >&2
    cat "$TMP_DIR/test4.log" >&2
    exit 1
fi
if ! grep -q "检测到已废弃的 IPQ8074 冲突补丁残留" "$TMP_DIR/test4.log"; then
    echo "FAIL: Error message did not report conflict patch: $(cat "$TMP_DIR/test4.log")" >&2
    exit 1
fi
echo "PASS: IPQ8074 conflict patch residual strictly blocked (exit code 1)."

# -----------------------------------------------------------------------------
# Test 5: 工作流无残留外挂调用门禁 (No Residual External Helper Invocations)
# -----------------------------------------------------------------------------
echo "--- Test 5: Verify workflow files have no residual external patch helper invocations ---"
if grep -q "prepare-qca8081-clock-fix.sh" "$WORKFLOW_FILE"; then
    echo "FAIL: Residual prepare-qca8081-clock-fix.sh found in $WORKFLOW_FILE!" >&2
    grep -n "prepare-qca8081-clock-fix.sh" "$WORKFLOW_FILE" >&2
    exit 1
fi
if grep -q "Fix QCA8081 Port Clocks" "$WORKFLOW_FILE"; then
    echo "FAIL: Residual 'Fix QCA8081 Port Clocks' step found in $WORKFLOW_FILE!" >&2
    grep -n "Fix QCA8081 Port Clocks" "$WORKFLOW_FILE" >&2
    exit 1
fi

ALL_WF_RESIDUALS=$(grep -rn "prepare-qca8081-clock-fix" "$REPO_ROOT/.github/workflows" 2>/dev/null || true)
if [ -n "$ALL_WF_RESIDUALS" ]; then
    echo "FAIL: Residual references found in .github/workflows:" >&2
    echo "$ALL_WF_RESIDUALS" >&2
    exit 1
fi
echo "PASS: Workflows are completely clean of obsolete external helper scripts."

# -----------------------------------------------------------------------------
# Test 6: 冗余外挂文件清理门禁 (External Out-of-tree Files Physically Cleaned)
# -----------------------------------------------------------------------------
echo "--- Test 6: Verify out-of-tree patch files and scripts are deleted from repo ---"
if [ -f "$REPO_ROOT/Patches/qualcommax-qca8081-clock-fix.patch" ]; then
    echo "FAIL: Patches/qualcommax-qca8081-clock-fix.patch still exists in repository!" >&2
    exit 1
fi
if [ -f "$REPO_ROOT/.github/scripts/prepare-qca8081-clock-fix.sh" ]; then
    echo "FAIL: .github/scripts/prepare-qca8081-clock-fix.sh still exists in repository!" >&2
    exit 1
fi
if [ ! -f "$REPO_ROOT/Patches/README.md" ]; then
    echo "FAIL: Patches/README.md missing!" >&2
    exit 1
fi
if ! grep -q "原生内置说明" "$REPO_ROOT/Patches/README.md"; then
    echo "FAIL: Patches/README.md not updated with native upstream integration documentation!" >&2
    exit 1
fi
echo "PASS: Obsolete patch and script files physically deleted; README updated."

echo "=== All QCA8081 Native Clock Fix Assertion & Regression Tests Passed! ==="
