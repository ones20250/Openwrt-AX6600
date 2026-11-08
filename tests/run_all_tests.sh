#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# AX6600 Unified Test Suite Runner (跨平台全量测试聚合运行器)
# Supports Linux and Windows Git Bash environments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 确保在仓库根目录执行，保证路径一致性
cd "$REPO_ROOT"

# 跨平台 Bash 执行环境探测
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
    elif command -v git >/dev/null 2>&1; then
        GIT_DIR="$(dirname "$(dirname "$(command -v git)")")"
        if [ -x "$GIT_DIR/bin/bash.exe" ]; then
            BASH_BIN="$GIT_DIR/bin/bash.exe"
        elif [ -x "$GIT_DIR/usr/bin/bash.exe" ]; then
            BASH_BIN="$GIT_DIR/usr/bin/bash.exe"
        fi
    else
        BASH_BIN="sh"
    fi
fi

# 待执行的 7 个核心单元与回归测试脚本列表 (按序执行)
TEST_SUITES=(
    "test_config_assertion.sh:CI 配置断言与意图感知回归测试 (PLUS 插件 & PPE 驱动 & firewall4 & 目标机型)"
    "test_wifi_default_config.sh:WiFi 默认配置注入与三频合规初始化回归测试"
    "test_qca8081_clock_fix.sh:Qualcomm PPE QCA8081 时钟补丁集成回归测试"
    "test_wolultra_configuration.sh:wolultra 网络唤醒插件配置与 CI 断言回归测试"
    "test_ci_defconfig_exit.sh:CI 构建流程 defconfig 退出码阻断回归测试"
    "test_upgrade_and_backup_consistency.sh:保留配置升级与 Docker 备份恢复规范一致性测试"
    "test_docker_upgrade_helper.sh:Docker 备份恢复与升级验证辅助脚本深度沙箱演练"
)

TOTAL_COUNT=${#TEST_SUITES[@]}
PASSED_COUNT=0
FAILED_COUNT=0

declare -a TEST_NAMES
declare -a TEST_DESCS
declare -a TEST_STATUSES
declare -a TEST_DURATIONS

START_TOTAL=$(date +%s)

echo "================================================================================"
echo "          京东云雅典娜 AX6600 (IPQ6010) 全量单元与回归测试套件看板"
echo "================================================================================"
echo "工作区根目录: $REPO_ROOT"
echo "Bash 解释器:   $BASH_BIN"
echo "总测试用例数: $TOTAL_COUNT"
echo "================================================================================"
echo ""

INDEX=0
for ENTRY in "${TEST_SUITES[@]}"; do
    INDEX=$((INDEX + 1))
    SCRIPT_NAME="${ENTRY%%:*}"
    SCRIPT_DESC="${ENTRY#*:}"
    SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

    TEST_NAMES+=("$SCRIPT_NAME")
    TEST_DESCS+=("$SCRIPT_DESC")

    echo ">>> [$INDEX/$TOTAL_COUNT] 正在执行: $SCRIPT_NAME"
    echo "    说明: $SCRIPT_DESC"

    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "::error::测试脚本不存在: $SCRIPT_PATH" >&2
        TEST_STATUSES+=("MISSING")
        TEST_DURATIONS+=("0s")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    T_START=$(date +%s)
    set +e
    "$BASH_BIN" "$SCRIPT_PATH"
    RUN_EXIT=$?
    set -e
    T_END=$(date +%s)
    DURATION=$((T_END - T_START))
    TEST_DURATIONS+=("${DURATION}s")

    if [ $RUN_EXIT -eq 0 ]; then
        TEST_STATUSES+=("PASS")
        PASSED_COUNT=$((PASSED_COUNT + 1))
        echo "--- [$INDEX/$TOTAL_COUNT] 结果: [PASS] 耗时 ${DURATION}s ---"
    else
        TEST_STATUSES+=("FAIL")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "--- [$INDEX/$TOTAL_COUNT] 结果: [FAIL] 退出码 $RUN_EXIT (耗时 ${DURATION}s) ---" >&2
    fi
    echo ""
done

END_TOTAL=$(date +%s)
TOTAL_DURATION=$((END_TOTAL - START_TOTAL))

echo "================================================================================"
echo "                             测试结果汇总看板"
echo "================================================================================"
printf "%s | %s%*s | %s%*s | %s\n" "序号" "测试脚本" 32 "" "耗时" 4 "" "状态  "
echo "-----+------------------------------------------+----------+--------"

for i in "${!TEST_NAMES[@]}"; do
    SEQ=$((i + 1))
    NAME="${TEST_NAMES[$i]}"
    STATUS="${TEST_STATUSES[$i]}"
    DUR="${TEST_DURATIONS[$i]}"
    if [ "$STATUS" = "PASS" ]; then
        STATUS_FMT=" PASS "
    else
        STATUS_FMT="*FAIL*"
    fi
    printf "%-4d | %-40s | %-8s | [%s]\n" "$SEQ" "$NAME" "$DUR" "$STATUS_FMT"
done

echo "================================================================================"
echo "总测试数: $TOTAL_COUNT | 通过: $PASSED_COUNT | 失败: $FAILED_COUNT | 总耗时: ${TOTAL_DURATION}s"
echo "================================================================================"

if [ $FAILED_COUNT -ne 0 ]; then
    echo "::error::测试套件执行失败，存在 $FAILED_COUNT 个未通过测试！" >&2
    exit 1
fi

echo "全部 $TOTAL_COUNT 项测试 100% 绿色通过！"
exit 0
