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

echo "=== All Intent-Aware Dynamic Assertion Regression Tests Passed! ==="
