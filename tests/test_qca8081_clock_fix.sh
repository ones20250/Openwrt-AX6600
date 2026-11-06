#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regression Test: Verify QCA8081 Clock Fix patch integration and workflow safety.
# Supports standalone execution with built-in fixture as well as external source validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/.github/scripts/prepare-qca8081-clock-fix.sh"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/WRT-CORE.yml"

DRIVER="target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c"
TARGET="target/linux/qualcommax/Makefile"

SOURCE="${1:-}"
FIXTURE="$REPO_ROOT/tests/fixtures/qca_ppe_main_clean.c"

if [ -n "$SOURCE" ]; then
    SOURCE=$(cd "$SOURCE" && pwd)
    echo "=== Running QCA8081 Clock Fix Regression Test (against provided source: $SOURCE) ==="
    test -f "$SOURCE/$DRIVER"
    test -f "$SOURCE/$TARGET"
else
    echo "=== Running QCA8081 Clock Fix Regression Test (Standalone Fixture Mode) ==="
    if [ ! -f "$FIXTURE" ]; then
        echo "FAIL: Test fixture not found at $FIXTURE" >&2
        exit 1
    fi
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'qca_test')"
trap 'rm -rf "$TMP"' EXIT

fresh_tree() {
    TREE="$TMP/$1"
    mkdir -p "$TREE/$(dirname "$DRIVER")"
    mkdir -p "$TREE/$(dirname "$TARGET")"
    if [ -n "$SOURCE" ]; then
        cp "$SOURCE/$DRIVER" "$TREE/$DRIVER"
        cp "$SOURCE/$TARGET" "$TREE/$TARGET"
    else
        cp "$FIXTURE" "$TREE/$DRIVER"
        printf "KERNEL_PATCHVER:=6.18\n" > "$TREE/$TARGET"
    fi
    git -C "$TREE" init -q
}

run_helper() { (cd "$TREE" && bash "$HELPER"); }
snapshot() { (cd "$TREE" && find target -type f -print0 | sort -z | xargs -0 sha256sum); }

# 1. 干净源码首次应用与幂等性校验
fresh_tree clean
run_helper
grep -q 'ret = clk_set_parent(rcg, parent);' "$TREE/$DRIVER"
grep -q 'ret = ppe_port_clk_parents(priv);' "$TREE/$DRIVER"
test -s "$TREE/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
test -s "$TREE/target/linux/qualcommax/patches-6.18/0919-clk-qcom-gcc-ipq8074-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
snapshot > "$TMP/once"
run_helper
snapshot > "$TMP/twice"
cmp "$TMP/once" "$TMP/twice"
echo 'PASS: complete fix applies cleanly and repeated application is idempotent'

# 2. 源码上下文漂移时的原子性防护（不可部分打入）
fresh_tree drift
sed -i 's/ppe_scheduler_init(priv);/ppe_scheduler_init_changed(priv);/' "$TREE/$DRIVER"
snapshot > "$TMP/drift-before"
if run_helper > "$TMP/drift.log" 2>&1; then
    echo 'FAIL: incompatible source was accepted' >&2; exit 1
fi
snapshot > "$TMP/drift-after"
cmp "$TMP/drift-before" "$TMP/drift-after"
echo 'PASS: source drift fails safely without leaving partially applied patches'

# 3. 补丁部分已存在时的识别校验
fresh_tree partial
mkdir -p "$TREE/target/linux/qualcommax/patches-6.18"
cp "$TMP/clean/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch" "$TREE/target/linux/qualcommax/patches-6.18/"
snapshot > "$TMP/partial-before"
if run_helper > "$TMP/partial.log" 2>&1; then
    echo 'FAIL: incomplete existing fix was accepted' >&2; exit 1
fi
snapshot > "$TMP/partial-after"
cmp "$TMP/partial-before" "$TMP/partial-after"
echo 'PASS: incomplete existing fix fails without modifying source'

# 4. 非目标内核版本（如 6.12）时的拦截校验
fresh_tree kernel
sed -i 's/KERNEL_PATCHVER:=6.18/KERNEL_PATCHVER:=6.12/' "$TREE/$TARGET"
snapshot > "$TMP/kernel-before"
if run_helper > "$TMP/kernel.log" 2>&1; then
    echo 'FAIL: unsupported PPE kernel was accepted' >&2; exit 1
fi
snapshot > "$TMP/kernel-after"
cmp "$TMP/kernel-before" "$TMP/kernel-after"
echo 'PASS: unsupported kernel fails without modification'

# 5. 非 PPE 树的无害跳过校验（非 CI 环境）
TREE="$TMP/non-ppe"
mkdir -p "$TREE"
CI=false GITHUB_ACTIONS=false run_helper
test -z "$(find "$TREE" -type f -print -quit)"
echo 'PASS: non-PPE source is safely skipped in non-CI environments'

# 6. CI 环境下非 PPE 树的强制报错阻断校验（防静默失效）
TREE="$TMP/ci-missing-ppe"
mkdir -p "$TREE"
if CI=true GITHUB_ACTIONS=true run_helper > "$TMP/ci-fail.log" 2>&1; then
    echo 'FAIL: missing PPE driver in CI environment should have failed!' >&2; exit 1
fi
echo 'PASS: missing PPE driver in CI environment is strictly blocked (no silent skip)'

# 7. 工作流步骤时序验证（纯原生 Bash，跨平台免 Python 依赖与编码冲突）
if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "FAIL: $WORKFLOW_FILE not found" >&2
    exit 1
fi

CLONE_LINE=$(grep -n -- "- name: Clone Code" "$WORKFLOW_FILE" | head -n 1 | cut -d: -f1 || true)
HELPER_LINE=$(grep -n -- "prepare-qca8081-clock-fix.sh" "$WORKFLOW_FILE" | head -n 1 | cut -d: -f1 || true)
FEEDS_LINE=$(grep -n -- "- name: Update Feeds" "$WORKFLOW_FILE" | head -n 1 | cut -d: -f1 || true)

if [ -n "$CLONE_LINE" ] && [ -n "$HELPER_LINE" ] && [ -n "$FEEDS_LINE" ] && \
   [ "$CLONE_LINE" -lt "$HELPER_LINE" ] && [ "$HELPER_LINE" -lt "$FEEDS_LINE" ]; then
    echo 'PASS: shared workflow applies the fix before configuration for PURE and PLUS'
else
    echo "FAIL: workflow step ordering is invalid: Clone=$CLONE_LINE, Helper=$HELPER_LINE, Feeds=$FEEDS_LINE" >&2
    exit 1
fi

echo "=== All QCA8081 Clock Fix Regression Tests Passed! ==="
