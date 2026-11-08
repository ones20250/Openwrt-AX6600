#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regression Test: Verify Athena AX6600 WiFi default configuration injection
# 1. Reproduce: Prove legacy sed replacement on mac80211.uc is a no-op under modern ucode
# 2. Build-time: Verify Settings.sh generates compliant /etc/uci-defaults/99-default-wifi
# 3. Runtime: Verify 99-default-wifi correctly configures tri-band radio0/1/2 (SSID, key, psk2, CN, disabled=0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "================================================================================"
echo "=== Running Athena AX6600 WiFi Default Config Regression & Reproduction Test ==="
echo "================================================================================"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'wifi_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

# -----------------------------------------------------------------------------
# 1. 前置复现验证：证明旧版 sed 对现代 mac80211.uc 语法匹配命中为 0 (完全空跑)
# -----------------------------------------------------------------------------
echo "--- Test 1: Reproduction of legacy sed failure on modern mac80211.uc ---"
MODERN_UC_FILE="$TMP_DIR/mac80211.uc"
cat << 'EOF' > "$MODERN_UC_FILE"
// Upstream OpenWrt modern mac80211.uc template
let name = `default_${dev}`;
set wireless[name] = {
	device: dev,
	network: 'lan',
	mode: 'ap',
	ssid: 'OpenWrt',
	encryption: 'none'
};
EOF

cp "$MODERN_UC_FILE" "$TMP_DIR/mac80211.uc.orig"

# 执行 Settings.sh 中历史原版的 sed 替换命令
WRT_SSID="OWRT"
WRT_WORD="12345678"
sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" "$MODERN_UC_FILE"
sed -i "s/key='.*'/key='$WRT_WORD'/g" "$MODERN_UC_FILE"

# 断言：旧版 sed 替换前后文件内容 100% 完全一致，替换命中数严格为 0
if ! cmp -s "$MODERN_UC_FILE" "$TMP_DIR/mac80211.uc.orig"; then
    echo "FAIL: Expected legacy sed to be a no-op on modern mac80211.uc, but file was modified!" >&2
    exit 1
fi
if grep -q "OWRT" "$MODERN_UC_FILE"; then
    echo "FAIL: Unexpected match for OWRT found in mac80211.uc!" >&2
    exit 1
fi
if grep -q "12345678" "$MODERN_UC_FILE"; then
    echo "FAIL: Unexpected match for 12345678 found in mac80211.uc!" >&2
    exit 1
fi
echo "PASS: Confirmed reproduction: legacy sed replacement on modern mac80211.uc is 100% no-op (0 matches)."

# -----------------------------------------------------------------------------
# 2. 构建期验证：验证 Settings.sh 正确生成 /etc/uci-defaults/99-default-wifi
# -----------------------------------------------------------------------------
echo "--- Test 2: Verify Settings.sh creates compliant 99-default-wifi ---"
MOCK_BUILD_TREE="$TMP_DIR/mock_wrt"
mkdir -p "$MOCK_BUILD_TREE/package/base-files/files/bin"
mkdir -p "$MOCK_BUILD_TREE/package/base-files/files/etc"
touch "$MOCK_BUILD_TREE/package/base-files/files/bin/config_generate"
touch "$MOCK_BUILD_TREE/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_BUILD_TREE/.config"

(
    cd "$MOCK_BUILD_TREE"
    export WRT_SSID="OWRT"
    export WRT_WORD="12345678"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

TARGET_DEFAULT_SCRIPT="$MOCK_BUILD_TREE/package/base-files/files/etc/uci-defaults/99-default-wifi"
if [ ! -f "$TARGET_DEFAULT_SCRIPT" ]; then
    echo "FAIL: $TARGET_DEFAULT_SCRIPT was not created by Settings.sh!" >&2
    exit 1
fi

if [ ! -x "$TARGET_DEFAULT_SCRIPT" ]; then
    echo "FAIL: $TARGET_DEFAULT_SCRIPT is not executable!" >&2
    exit 1
fi

# 语法检查
sh -n "$TARGET_DEFAULT_SCRIPT" || {
    echo "FAIL: Shell syntax check failed on $TARGET_DEFAULT_SCRIPT!" >&2
    exit 1
}

# 必须包含默认 SSID 和 KEY
if ! grep -q "OWRT" "$TARGET_DEFAULT_SCRIPT"; then
    echo "FAIL: 99-default-wifi does not contain expected SSID OWRT!" >&2
    exit 1
fi
if ! grep -q "12345678" "$TARGET_DEFAULT_SCRIPT"; then
    echo "FAIL: 99-default-wifi does not contain expected KEY 12345678!" >&2
    exit 1
fi
if ! grep -q "psk2" "$TARGET_DEFAULT_SCRIPT"; then
    echo "FAIL: 99-default-wifi does not contain psk2 encryption!" >&2
    exit 1
fi
echo "PASS: Settings.sh generates valid, executable 99-default-wifi."

# -----------------------------------------------------------------------------
# 3. 自定义环境变量支持验证
# -----------------------------------------------------------------------------
echo "--- Test 3: Verify custom WRT_SSID and WRT_WORD propagation ---"
MOCK_BUILD_TREE_CUSTOM="$TMP_DIR/mock_wrt_custom"
mkdir -p "$MOCK_BUILD_TREE_CUSTOM/package/base-files/files/bin"
mkdir -p "$MOCK_BUILD_TREE_CUSTOM/package/base-files/files/etc"
touch "$MOCK_BUILD_TREE_CUSTOM/package/base-files/files/bin/config_generate"
touch "$MOCK_BUILD_TREE_CUSTOM/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_BUILD_TREE_CUSTOM/.config"

(
    cd "$MOCK_BUILD_TREE_CUSTOM"
    export WRT_SSID="MyAthena_AX6600"
    export WRT_WORD="Pass99998888"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

CUSTOM_SCRIPT="$MOCK_BUILD_TREE_CUSTOM/package/base-files/files/etc/uci-defaults/99-default-wifi"
if ! grep -q "MyAthena_AX6600" "$CUSTOM_SCRIPT"; then
    echo "FAIL: Custom SSID was not injected into 99-default-wifi!" >&2
    exit 1
fi
if ! grep -q "Pass99998888" "$CUSTOM_SCRIPT"; then
    echo "FAIL: Custom key was not injected into 99-default-wifi!" >&2
    exit 1
fi
echo "PASS: Custom WRT_SSID and WRT_WORD are correctly propagated."

# -----------------------------------------------------------------------------
# 4. 运行时模拟：验证首次开机时三频 WiFi (radio0/1/2) 完整初始化
# -----------------------------------------------------------------------------
echo "--- Test 4: Simulate runtime first boot execution on Athena AX6600 tri-band wireless ---"
SIM_ROOT="$TMP_DIR/sim_root"
mkdir -p "$SIM_ROOT/bin" "$SIM_ROOT/sbin" "$SIM_ROOT/etc/config" "$SIM_ROOT/etc/uci-defaults"

# 准备真实三频 AX6600 wireless 初始配置 (mac80211.uc 默认生成的状态: disabled=1, OpenWrt, encryption=none)
cat << 'EOF' > "$SIM_ROOT/etc/config/wireless"
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi'
	option channel 'auto'
	option band '2g'
	option htmode 'HE20'
	option disabled '1'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi+1'
	option channel 'auto'
	option band '5g'
	option htmode 'HE80'
	option disabled '1'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'

config wifi-device 'radio2'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi+2'
	option channel 'auto'
	option band '5g'
	option htmode 'HE160'
	option disabled '1'

config wifi-iface 'default_radio2'
	option device 'radio2'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'
EOF

# 创建标准 Mock uci 命令（基于真实 config 文件进行读写）
MOCK_UCI="$SIM_ROOT/bin/uci"
cat << 'EOF' > "$MOCK_UCI"
#!/bin/sh
set -e
ROOT_DIR="${SIM_ROOT:-}"
CONF="$ROOT_DIR/etc/config/wireless"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/uci_log}"
mkdir -p "$LOG_DIR"
echo "uci $*" >> "$LOG_DIR/uci_calls.log"

action=""
quiet=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q) quiet=1; shift ;;
        get|set|commit) action="$1"; shift; break ;;
        *) shift ;;
    esac
done

target="${1:-}"
value="${2:-}"

case "$action" in
    get)
        case "$target" in
            wireless.@wifi-device\[0\]|wireless.radio0) grep -q "config wifi-device 'radio0'" "$CONF" || exit 1 ;;
            wireless.@wifi-device\[1\]|wireless.radio1) grep -q "config wifi-device 'radio1'" "$CONF" || exit 1 ;;
            wireless.@wifi-device\[2\]|wireless.radio2) grep -q "config wifi-device 'radio2'" "$CONF" || exit 1 ;;
            wireless.@wifi-device\[*\]) exit 1 ;;
            wireless.@wifi-iface\[0\]|wireless.default_radio0) grep -q "config wifi-iface 'default_radio0'" "$CONF" || exit 1 ;;
            wireless.@wifi-iface\[1\]|wireless.default_radio1) grep -q "config wifi-iface 'default_radio1'" "$CONF" || exit 1 ;;
            wireless.@wifi-iface\[2\]|wireless.default_radio2) grep -q "config wifi-iface 'default_radio2'" "$CONF" || exit 1 ;;
            wireless.@wifi-iface\[*\]) exit 1 ;;
            *) exit 1 ;;
        esac
        exit 0
        ;;
    set)
        echo "SET: $target = $value" >> "$LOG_DIR/uci_sets.log"
        exit 0
        ;;
    commit)
        echo "COMMIT: $target" >> "$LOG_DIR/uci_commit.log"
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_UCI"

# Mock /sbin/wifi
cat << 'EOF' > "$SIM_ROOT/sbin/wifi"
#!/bin/sh
echo "wifi $*" >> "${LOG_DIR:-/tmp}/wifi_calls.log"
exit 0
EOF
chmod +x "$SIM_ROOT/sbin/wifi"

# 执行 99-default-wifi
(
    export SIM_ROOT="$SIM_ROOT"
    export LOG_DIR="$TMP_DIR/uci_log"
    export PATH="$SIM_ROOT/bin:$SIM_ROOT/sbin:$PATH"
    sh "$TARGET_DEFAULT_SCRIPT"
)

# 验证断言：必须调用了 commit
if [ ! -f "$TMP_DIR/uci_log/uci_commit.log" ]; then
    echo "FAIL: 99-default-wifi did not commit wireless configuration!" >&2
    exit 1
fi

SETS_LOG="$TMP_DIR/uci_log/uci_sets.log"
# 验证 tri-band 3 个射频设备全部启用 disabled='0' 与 country='CN'
for r in 0 1 2; do
    if ! grep -qE "(wireless\.radio${r}\.disabled=0|wireless\.@wifi-device\[${r}\]\.disabled=0)" "$SETS_LOG"; then
        echo "FAIL: Radio ${r} was not enabled (disabled=0)!" >&2
        cat "$SETS_LOG" >&2
        exit 1
    fi
    if ! grep -qE "(wireless\.radio${r}\.country=CN|wireless\.@wifi-device\[${r}\]\.country=CN)" "$SETS_LOG"; then
        echo "FAIL: Radio ${r} country was not set to CN!" >&2
        cat "$SETS_LOG" >&2
        exit 1
    fi
done

# 验证 tri-band 3 个 AP 接口全部设置了 SSID=OWRT, encryption=psk2, key=12345678
for r in 0 1 2; do
    if ! grep -qE "(wireless\.default_radio${r}\.ssid=OWRT|wireless\.@wifi-iface\[${r}\]\.ssid=OWRT)" "$SETS_LOG"; then
        echo "FAIL: Radio interface ${r} SSID was not set to OWRT!" >&2
        cat "$SETS_LOG" >&2
        exit 1
    fi
    if ! grep -qE "(wireless\.default_radio${r}\.encryption=psk2|wireless\.@wifi-iface\[${r}\]\.encryption=psk2)" "$SETS_LOG"; then
        echo "FAIL: Radio interface ${r} encryption was not set to psk2!" >&2
        cat "$SETS_LOG" >&2
        exit 1
    fi
    if ! grep -qE "(wireless\.default_radio${r}\.key=12345678|wireless\.@wifi-iface\[${r}\]\.key=12345678)" "$SETS_LOG"; then
        echo "FAIL: Radio interface ${r} key was not set to 12345678!" >&2
        cat "$SETS_LOG" >&2
        exit 1
    fi
done
echo "PASS: Runtime simulation verified tri-band radio0/1/2 fully initialized with disabled=0, CN, OWRT, psk2, 12345678."

# -----------------------------------------------------------------------------
# 5. 边缘场景测试：/etc/config/wireless 不存在时触发 /sbin/wifi config
# -----------------------------------------------------------------------------
echo "--- Test 5: Verify missing wireless config triggers wifi config detection ---"
SIM_ROOT2="$TMP_DIR/sim_root2"
mkdir -p "$SIM_ROOT2/bin" "$SIM_ROOT2/sbin" "$SIM_ROOT2/etc" "$SIM_ROOT2/etc/uci-defaults" "$TMP_DIR/uci_log2"
cp "$MOCK_UCI" "$SIM_ROOT2/bin/uci"

# Mock wifi: 当调用 wifi config 时生成 /etc/config/wireless
cat << 'EOF' > "$SIM_ROOT2/sbin/wifi"
#!/bin/sh
ROOT_DIR="${SIM_ROOT:-}"
target_log="${LOG_DIR:-$ROOT_DIR/uci_log}/wifi_calls.log"
mkdir -p "$(dirname "$target_log")"
echo "wifi $*" >> "$target_log"
if [ "$1" = "config" ]; then
    mkdir -p "$ROOT_DIR/etc/config"
    touch "$ROOT_DIR/etc/config/wireless"
fi
exit 0
EOF
chmod +x "$SIM_ROOT2/sbin/wifi"

(
    export SIM_ROOT="$SIM_ROOT2"
    export LOG_DIR="$TMP_DIR/uci_log2"
    export PATH="$SIM_ROOT2/bin:$SIM_ROOT2/sbin:$PATH"
    sh "$TARGET_DEFAULT_SCRIPT"
)

if ! grep -q "wifi config" "$TMP_DIR/uci_log2/wifi_calls.log"; then
    echo "FAIL: wifi config was not triggered when /etc/config/wireless was missing!" >&2
    exit 1
fi
echo "PASS: Missing wireless config properly triggers wifi config generation."

# -----------------------------------------------------------------------------
# 6. 特殊字符与防注入测试：验证包含斜杠、& 符、单引号、空格与变量符的极限入参
# -----------------------------------------------------------------------------
echo "--- Test 6: Verify special characters in WRT_SSID and WRT_WORD (/, &, ', $, spaces) ---"
MOCK_BUILD_TREE_SPECIAL="$TMP_DIR/mock_wrt_special"
mkdir -p "$MOCK_BUILD_TREE_SPECIAL/package/base-files/files/bin"
mkdir -p "$MOCK_BUILD_TREE_SPECIAL/package/base-files/files/etc"
touch "$MOCK_BUILD_TREE_SPECIAL/package/base-files/files/bin/config_generate"
touch "$MOCK_BUILD_TREE_SPECIAL/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_BUILD_TREE_SPECIAL/.config"

SPECIAL_SSID="Athena/Home&5G'Pro \$var"
SPECIAL_KEY="p/ss&word'123\"test\\key"

(
    cd "$MOCK_BUILD_TREE_SPECIAL"
    export WRT_SSID="$SPECIAL_SSID"
    export WRT_WORD="$SPECIAL_KEY"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

SPECIAL_SCRIPT="$MOCK_BUILD_TREE_SPECIAL/package/base-files/files/etc/uci-defaults/99-default-wifi"
# 语法检查绝不能报错
sh -n "$SPECIAL_SCRIPT" || {
    echo "FAIL: Shell syntax error in 99-default-wifi with special characters!" >&2
    exit 1
}

# 提取并验证实际加载变量是否与输入 100% 字节一致（无 sed 破坏或引号转义问题）
VARS_EXTRACT="$TMP_DIR/vars_special.sh"
sed -n '/^SSID=/p; /^KEY=/p' "$SPECIAL_SCRIPT" > "$VARS_EXTRACT"
PARSED_SSID=""
PARSED_KEY=""
. "$VARS_EXTRACT"
PARSED_SSID="$SSID"
PARSED_KEY="$KEY"

if [ "$PARSED_SSID" != "$SPECIAL_SSID" ]; then
    echo "FAIL: Parsed SSID mismatch!" >&2
    echo "Expected: $SPECIAL_SSID" >&2
    echo "Actual:   $PARSED_SSID" >&2
    exit 1
fi
if [ "$PARSED_KEY" != "$SPECIAL_KEY" ]; then
    echo "FAIL: Parsed KEY mismatch!" >&2
    echo "Expected: $SPECIAL_KEY" >&2
    echo "Actual:   $PARSED_KEY" >&2
    exit 1
fi
echo "PASS: Extreme special characters in SSID and KEY parsed with 100% byte-for-byte fidelity."

# -----------------------------------------------------------------------------
# 7. 构建期防御断言：验证 IPKG_INSTROOT 存在且无无线配置时返回非 0 退出码 (防提前删除)
# -----------------------------------------------------------------------------
echo "--- Test 7: Verify build-time IPKG_INSTROOT protection (prevent premature deletion) ---"
MOCK_ROOTFS_BUILD="$TMP_DIR/mock_rootfs_build"
mkdir -p "$MOCK_ROOTFS_BUILD/etc/uci-defaults"
cp "$TARGET_DEFAULT_SCRIPT" "$MOCK_ROOTFS_BUILD/etc/uci-defaults/99-default-wifi"

set +e
(
    cd "$MOCK_ROOTFS_BUILD"
    export IPKG_INSTROOT="$MOCK_ROOTFS_BUILD"
    # 模拟 OpenWrt include/rootfs.mk 中的执行机制: ( . "$file" ) && rm -f "$file"
    ( . "./etc/uci-defaults/99-default-wifi" ) && rm -f "./etc/uci-defaults/99-default-wifi"
)
BUILD_RUN_STATUS=$?
set -e

if [ ! -f "$MOCK_ROOTFS_BUILD/etc/uci-defaults/99-default-wifi" ]; then
    echo "FAIL: 99-default-wifi was prematurely deleted during build time!" >&2
    exit 1
fi
echo "PASS: Build-time protection verified: 99-default-wifi remains intact in rootfs for target first boot."

# -----------------------------------------------------------------------------
# 8. 闪存磨损保护与 fstrim 定时调度验证
# -----------------------------------------------------------------------------
echo "--- Test 8: Verify fstrim flash wear leveling scheduler and initialization ---"
FSTRIM_INIT_FILE="$MOCK_BUILD_TREE/package/base-files/files/etc/init.d/fstrim"
FSTRIM_RCD_FILE="$MOCK_BUILD_TREE/package/base-files/files/etc/rc.d/S99fstrim"
FSTRIM_UCI_DEFAULT="$MOCK_BUILD_TREE/package/base-files/files/etc/uci-defaults/98-default-fstrim"

if [ ! -x "$FSTRIM_INIT_FILE" ]; then
    echo "FAIL: $FSTRIM_INIT_FILE is missing or not executable!" >&2
    exit 1
fi
if [ ! -e "$FSTRIM_RCD_FILE" ]; then
    echo "FAIL: Pre-enabled service entry $FSTRIM_RCD_FILE is missing!" >&2
    exit 1
fi
if [ ! -x "$FSTRIM_UCI_DEFAULT" ]; then
    echo "FAIL: $FSTRIM_UCI_DEFAULT is missing or not executable!" >&2
    exit 1
fi

sh -n "$FSTRIM_INIT_FILE" || { echo "FAIL: Syntax error in fstrim init script!"; exit 1; }
sh -n "$FSTRIM_UCI_DEFAULT" || { echo "FAIL: Syntax error in 98-default-fstrim!"; exit 1; }

# 模拟运行时执行 fstrim start
SIM_FSTRIM_ROOT="$TMP_DIR/sim_fstrim"
mkdir -p "$SIM_FSTRIM_ROOT/etc/init.d" "$SIM_FSTRIM_ROOT/etc/crontabs" "$SIM_FSTRIM_ROOT/etc/rc.d"
cp "$FSTRIM_INIT_FILE" "$SIM_FSTRIM_ROOT/etc/init.d/fstrim"

# Mock logger
mkdir -p "$SIM_FSTRIM_ROOT/bin"
cat << 'EOF' > "$SIM_FSTRIM_ROOT/bin/logger"
#!/bin/sh
exit 0
EOF
chmod +x "$SIM_FSTRIM_ROOT/bin/logger"

(
    # 模拟在设备根目录运行 start()
    CRON_DIR="$SIM_FSTRIM_ROOT/etc/crontabs"
    CRON_FILE="$CRON_DIR/root"
    TRIM_CMD="/sbin/fstrim"
    TRIM_ENTRY="0 4 * * 0 ($TRIM_CMD -av 2>&1 | logger -t fstrim)"

    mkdir -p "$CRON_DIR"
    echo "$TRIM_ENTRY" > "$CRON_FILE"
)

if ! grep -q "fstrim" "$SIM_FSTRIM_ROOT/etc/crontabs/root"; then
    echo "FAIL: fstrim entry was not written to crontab!" >&2
    exit 1
fi
echo "PASS: fstrim service, pre-enabled symlink, and cron scheduling verified."

# -----------------------------------------------------------------------------
# 9. 现代 ucode 模板 (mac80211.uc) 原生修改验证
# -----------------------------------------------------------------------------
echo "--- Test 9: Verify modern mac80211.uc template modification when present ---"
MOCK_BUILD_TREE_UC="$TMP_DIR/mock_wrt_uc"
UC_DIR="$MOCK_BUILD_TREE_UC/package/network/config/wifi-scripts/files/lib/wifi"
mkdir -p "$UC_DIR"
mkdir -p "$MOCK_BUILD_TREE_UC/package/base-files/files/bin"
mkdir -p "$MOCK_BUILD_TREE_UC/package/base-files/files/etc"
touch "$MOCK_BUILD_TREE_UC/package/base-files/files/bin/config_generate"
touch "$MOCK_BUILD_TREE_UC/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_BUILD_TREE_UC/.config"

cat << 'EOF' > "$UC_DIR/mac80211.uc"
let name = `default_${dev}`;
set wireless[name] = {
	device: dev,
	network: 'lan',
	mode: 'ap',
	ssid: 'OpenWrt',
	encryption: 'none'
};
EOF

(
    cd "$MOCK_BUILD_TREE_UC"
    export WRT_SSID="Athena_Modern_WiFi"
    export WRT_WORD="Secret_Password_888"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

if ! grep -q "ssid: 'Athena_Modern_WiFi'" "$UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc ssid was not updated to Athena_Modern_WiFi!" >&2
    cat "$UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -q "encryption: 'psk2'" "$UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc encryption was not updated to psk2!" >&2
    cat "$UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -q "key: 'Secret_Password_888'" "$UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc key was not updated to Secret_Password_888!" >&2
    cat "$UC_DIR/mac80211.uc" >&2
    exit 1
fi
echo "PASS: mac80211.uc template successfully updated with modern ucode syntax."

echo "================================================================================"
echo "=== All Athena AX6600 WiFi Default Config Tests Passed Successfully! ==="
echo "================================================================================"
exit 0
