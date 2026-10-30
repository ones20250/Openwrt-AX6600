#!/usr/bin/env bash
# Regression Test: Verify defconfig failure immediately terminates CI step under bash -e
# This prevents swallowed errors and ensures configuration assertions are not executed on failed defconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/WRT-CORE.yml"
BASH_BIN="${BASH:-bash}"

echo "=== Running CI Regression Test: defconfig Exit Code 42 Termination ==="

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "ERROR: Workflow file not found at $WORKFLOW_FILE" >&2
    exit 1
fi

# Test 1: Static YAML verification - ensure make defconfig and make clean are NOT on the same line with &&
echo "--- Test 1: Static check in WRT-CORE.yml ---"
if grep -E 'make\s+defconfig.*&&.*make\s+clean' "$WORKFLOW_FILE"; then
    echo "FAIL: Found chained 'make defconfig && make clean' in $WORKFLOW_FILE!" >&2
    exit 1
fi

if ! grep -E '^\s*make\s+defconfig\s+-j\$\(nproc\)\s*$' "$WORKFLOW_FILE" >/dev/null; then
    echo "FAIL: 'make defconfig -j\$(nproc)' as independent command line not found in $WORKFLOW_FILE!" >&2
    exit 1
fi

if ! grep -E '^\s*make\s+clean\s+-j\$\(nproc\)\s*$' "$WORKFLOW_FILE" >/dev/null; then
    echo "FAIL: 'make clean -j\$(nproc)' as independent command line not found in $WORKFLOW_FILE!" >&2
    exit 1
fi
echo "PASS: Static verification passed (defconfig and clean are separated independent lines)."

# Test 2: Dynamic simulation under bash -e using commands extracted directly from WRT-CORE.yml
echo "--- Test 2: Dynamic simulation of exit 42 using extracted commands from WRT-CORE.yml ---"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'ci_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

CLEAN_CALLED_FLAG="$TMP_DIR/clean_called"
ASSERTION_CALLED_FLAG="$TMP_DIR/assertion_called"

# Extract actual snippet from WRT-CORE.yml
EXTRACTED_COMMANDS="$(awk '/make defconfig/{flag=1} /echo "=== 正在执行 \.config 配置断言校验 ==="/{print; flag=0} flag' "$WORKFLOW_FILE")"

if [ -z "$EXTRACTED_COMMANDS" ]; then
    echo "FAIL: Failed to extract defconfig/clean snippet from $WORKFLOW_FILE!" >&2
    exit 1
fi

# Create a mock environment mimicking the Custom Settings step execution
TEST_RUNNER="$TMP_DIR/run_test.sh"
cat << EOF > "$TEST_RUNNER"
#!/usr/bin/env bash
set -e

CLEAN_CALLED_FLAG="\$1"
ASSERTION_CALLED_FLAG="\$2"

make() {
    if [[ "\$1" == "defconfig"* ]]; then
        echo "[MOCK] make defconfig failing with exit 42"
        return 42
    elif [[ "\$1" == "clean"* ]]; then
        touch "\$CLEAN_CALLED_FLAG"
        echo "[MOCK] make clean called"
        return 0
    fi
    return 0
}

# Commands extracted directly from WRT-CORE.yml
$EXTRACTED_COMMANDS
touch "\$ASSERTION_CALLED_FLAG"
EOF

chmod +x "$TEST_RUNNER"

# Execute test runner under bash
set +e
"$BASH_BIN" "$TEST_RUNNER" "$CLEAN_CALLED_FLAG" "$ASSERTION_CALLED_FLAG"
EXIT_CODE=$?
set -e

echo "Observed exit code: $EXIT_CODE"

if [ "$EXIT_CODE" -ne 42 ]; then
    echo "FAIL: Expected exit code 42, but got $EXIT_CODE" >&2
    exit 1
fi

if [ -f "$CLEAN_CALLED_FLAG" ]; then
    echo "FAIL: make clean was executed despite defconfig failure!" >&2
    exit 1
fi

if [ -f "$ASSERTION_CALLED_FLAG" ]; then
    echo "FAIL: Subsequent assertions were reached despite defconfig failure!" >&2
    exit 1
fi

echo "PASS: defconfig failure (exit 42) immediately terminated execution."

# Test 3: Contrast with old buggy chained command
echo "--- Test 3: Verifying the old buggy pattern would have swallowed the error ---"
BUGGY_RUNNER="$TMP_DIR/run_buggy.sh"
cat << 'EOF' > "$BUGGY_RUNNER"
#!/usr/bin/env bash
set -e

ASSERTION_CALLED_FLAG="$1"

make() {
    if [[ "$1" == "defconfig"* ]]; then
        return 42
    fi
    return 0
}

# Buggy pattern: && in compound command
make defconfig -j$(nproc) && make clean -j$(nproc)

# In bash -e, execution continues here!
touch "$ASSERTION_CALLED_FLAG"
EOF

chmod +x "$BUGGY_RUNNER"

set +e
"$BASH_BIN" "$BUGGY_RUNNER" "$ASSERTION_CALLED_FLAG"
BUGGY_EXIT=$?
set -e

if [ ! -f "$ASSERTION_CALLED_FLAG" ]; then
    echo "FAIL: Expected old buggy pattern to leak into assertions, but assertion flag was not created!" >&2
    exit 1
fi

if [ "$BUGGY_EXIT" -ne 0 ]; then
    echo "FAIL: Expected old buggy pattern to swallow error code 42 and exit 0, but got $BUGGY_EXIT" >&2
    exit 1
fi

echo "PASS: Confirmed bug reproduction - old '&&' pattern swallowed defconfig failure (exit 42 -> 0) and leaked to assertions."

# Test 4: Success path verification using extracted commands from WRT-CORE.yml
echo "--- Test 4: Success path verification (defconfig succeeds) ---"
SUCCESS_RUNNER="$TMP_DIR/run_success.sh"
SUCCESS_CLEAN_FLAG="$TMP_DIR/success_clean"
SUCCESS_ASSERT_FLAG="$TMP_DIR/success_assert"

cat << EOF > "$SUCCESS_RUNNER"
#!/usr/bin/env bash
set -e

SUCCESS_CLEAN_FLAG="\$1"
SUCCESS_ASSERT_FLAG="\$2"

make() {
    if [[ "\$1" == "defconfig"* ]]; then
        return 0
    elif [[ "\$1" == "clean"* ]]; then
        touch "\$SUCCESS_CLEAN_FLAG"
        return 0
    fi
    return 0
}

# Commands extracted directly from WRT-CORE.yml
$EXTRACTED_COMMANDS
touch "\$SUCCESS_ASSERT_FLAG"
EOF

chmod +x "$SUCCESS_RUNNER"

"$BASH_BIN" "$SUCCESS_RUNNER" "$SUCCESS_CLEAN_FLAG" "$SUCCESS_ASSERT_FLAG"

if [ ! -f "$SUCCESS_CLEAN_FLAG" ]; then
    echo "FAIL: make clean was not called on success!" >&2
    exit 1
fi

if [ ! -f "$SUCCESS_ASSERT_FLAG" ]; then
    echo "FAIL: Assertion step was not reached on success!" >&2
    exit 1
fi

echo "PASS: Success path executed completely."

# Test 5: Verify README.md retains low temperature feature
echo "--- Test 5: Verify README.md line 21 low temperature feature retained ---"
README_FEATURE="- ❄️ **低温运行** - 移除 NSS 闭源高发热组件，待机温度显著降低 5~10℃"
if ! grep -Fxq -e "$README_FEATURE" "$REPO_ROOT/README.md"; then
    echo "FAIL: Low temperature feature notice missing or altered in README.md!" >&2
    echo "Expected exact line: $README_FEATURE" >&2
    exit 1
fi
echo "PASS: README.md retains exact low temperature feature notice."

echo "=== All CI regression tests passed successfully! ==="
