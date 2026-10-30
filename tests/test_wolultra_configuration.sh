#!/usr/bin/env bash
# Regression Test: Verify wolultra configuration, PURE isolation, and CI assertion
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Running wolultra configuration and CI assertion regression test ==="

# 1. 检查 Config/GENERAL_AX6600.txt
echo "--- Test 1: Verify Config/GENERAL_AX6600.txt has no wolplus, wolultra or partexp (PURE remains pure) ---"
if grep -q "CONFIG_PACKAGE_luci-app-wolplus" "$REPO_ROOT/Config/GENERAL_AX6600.txt"; then
    echo "FAIL: Found leftover wolplus in Config/GENERAL_AX6600.txt!" >&2
    exit 1
fi
if grep -q "CONFIG_PACKAGE_luci-app-wolultra" "$REPO_ROOT/Config/GENERAL_AX6600.txt"; then
    echo "FAIL: Found wolultra in Config/GENERAL_AX6600.txt! PURE must not integrate wolultra." >&2
    exit 1
fi
if grep -q "CONFIG_PACKAGE_luci-app-partexp" "$REPO_ROOT/Config/GENERAL_AX6600.txt"; then
    echo "FAIL: Found partexp in Config/GENERAL_AX6600.txt! PURE must not integrate partexp." >&2
    exit 1
fi
echo "PASS: Config/GENERAL_AX6600.txt is clean of wolplus, wolultra and partexp."

# 2. 检查 Config/GENERAL_AX6600_PLUS.txt
echo "--- Test 2: Verify Config/GENERAL_AX6600_PLUS.txt contains CONFIG_PACKAGE_luci-app-wolultra=y ---"
if ! grep -q "^CONFIG_PACKAGE_luci-app-wolultra=y" "$REPO_ROOT/Config/GENERAL_AX6600_PLUS.txt"; then
    echo "FAIL: CONFIG_PACKAGE_luci-app-wolultra=y not found in Config/GENERAL_AX6600_PLUS.txt!" >&2
    exit 1
fi
if grep -q "CONFIG_PACKAGE_luci-app-wolplus" "$REPO_ROOT/Config/GENERAL_AX6600_PLUS.txt"; then
    echo "FAIL: Old CONFIG_PACKAGE_luci-app-wolplus still found in Config/GENERAL_AX6600_PLUS.txt!" >&2
    exit 1
fi
echo "PASS: Config/GENERAL_AX6600_PLUS.txt correctly specifies wolultra and removes wolplus."

# 3. 检查 Scripts/Packages.sh
echo "--- Test 3: Verify Scripts/Packages.sh viking cleanup list contains both wolplus and wolultra ---"
if ! grep -E 'UPDATE_PACKAGE "viking" "ones20250/packages" "main" "" "[^"]*luci-app-wolultra[^"]*"' "$REPO_ROOT/Scripts/Packages.sh" >/dev/null; then
    echo "FAIL: Active viking UPDATE_PACKAGE in Scripts/Packages.sh does not include luci-app-wolultra in cleanup list!" >&2
    exit 1
fi
if ! grep -E 'UPDATE_PACKAGE "viking" "ones20250/packages" "main" "" "[^"]*luci-app-wolplus[^"]*"' "$REPO_ROOT/Scripts/Packages.sh" >/dev/null; then
    echo "FAIL: Active viking UPDATE_PACKAGE in Scripts/Packages.sh must retain legacy luci-app-wolplus in cleanup list to purge upstream feeds!" >&2
    exit 1
fi
echo "PASS: Scripts/Packages.sh correctly includes both luci-app-wolplus and luci-app-wolultra in viking cleanup list."

# 4. 检查 README.md
echo "--- Test 4: Verify README.md mentions wolultra and has no leftover wolplus ---"
if grep -q "wolplus" "$REPO_ROOT/README.md"; then
    echo "FAIL: Found leftover 'wolplus' in README.md!" >&2
    exit 1
fi
if ! grep -q "网络唤醒（wolultra）" "$REPO_ROOT/README.md"; then
    echo "FAIL: '网络唤醒（wolultra）' not found in README.md!" >&2
    exit 1
fi
echo "PASS: README.md correctly updated to wolultra."

# 5. 检查 .github/workflows/WRT-CORE.yml 中 PLUS 断言
echo "--- Test 5: Verify WRT-CORE.yml includes luci-app-wolultra in PLUS assertions ---"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/WRT-CORE.yml"
if ! grep -q "luci-app-wolultra" "$WORKFLOW_FILE"; then
    echo "FAIL: luci-app-wolultra not found in $WORKFLOW_FILE!" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'wol_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

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

# 动态模拟 CI 断言逻辑：提取 PLUS 插件断言块（基于语义锚点，避免硬编码行号因文件改动失效）
ASSERT_SNIPPET="$(awk '/# 5\. PLUS 核心插件入选断言/{flag=1; next} flag && /if \[\[.*FAIL/{flag=0} flag' "$WORKFLOW_FILE")"
if [ -z "$ASSERT_SNIPPET" ]; then
    echo "FAIL: Failed to extract PLUS assertion block from $WORKFLOW_FILE!" >&2
    exit 1
fi

TEST_SCRIPT="$TMP_DIR/test_assert.sh"
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

# 5a: 模拟 PLUS 配置全量入选（期望成功通过）
cat << 'EOF' > "$TMP_DIR/.config"
CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-wolultra=y
EOF

if ! "$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS"; then
    echo "FAIL: Expected PLUS assertion to pass when all 5 plugins are present!" >&2
    exit 1
fi
echo "PASS: PLUS assertion passes when luci-app-wolultra is present."

# 5b: 模拟 PLUS 配置漏选 wolultra（期望严格报错阻断构建）
cat << 'EOF' > "$TMP_DIR/.config"
CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-adguardhome=y
EOF

set +e
"$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PLUS" 2>/dev/null
ASSERT_EXIT=$?
set -e

if [ "$ASSERT_EXIT" -eq 0 ]; then
    echo "FAIL: Expected PLUS assertion to fail when luci-app-wolultra is missing!" >&2
    exit 1
fi
echo "PASS: PLUS assertion strictly fails (exit code $ASSERT_EXIT) when luci-app-wolultra is missing."

# 5c: 模拟 PURE 构建（不执行 PLUS 断言）
if ! "$BASH_BIN" "$TEST_SCRIPT" "$TMP_DIR/.config" "PURE"; then
    echo "FAIL: PURE build should not fail on missing PLUS plugins!" >&2
    exit 1
fi
echo "PASS: PURE build does not enforce PLUS plugins."

echo "=== All wolultra configuration and CI assertion tests passed! ==="
