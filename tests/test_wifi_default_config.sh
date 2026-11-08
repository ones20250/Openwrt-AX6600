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
# 1b. 前置复现验证：明确复现 cb41bda 中 99-default-wifi 在保留配置升级时无差别重置用户 WiFi 的 Bug
# -----------------------------------------------------------------------------
echo "--- Test 1b: Bug reproduction: prove cb41bda overwrites user WiFi during sysupgrade ---"
REPRO_DIR="$TMP_DIR/repro_upgrade"
mkdir -p "$REPRO_DIR/etc/config" "$REPRO_DIR/log"

# 用户已有自定义 WiFi 配置 (保留配置升级场景)
cat << 'EOF' > "$REPRO_DIR/etc/config/wireless"
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi'
	option channel '6'
	option band '2g'
	option htmode 'HE20'
	option disabled '0'
	option country 'US'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyCustomHome_2G'
	option encryption 'sae'
	option key 'SecretPass_99998888'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi+1'
	option channel '36'
	option band '5g'
	option htmode 'HE80'
	option disabled '0'
	option country 'US'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyCustomHome_5G'
	option encryption 'psk2'
	option key 'SecretPass_5G_Pro'
EOF

cp "$REPRO_DIR/etc/config/wireless" "$REPRO_DIR/etc/config/wireless.preserved"

# 模拟 cb41bda 提交中未做既有配置保护的原始 99-default-wifi 执行逻辑
MOCK_BUGGY_UCI_LOG="$REPRO_DIR/log/buggy_sets.log"
MOCK_BUGGY_UCI="$REPRO_DIR/mock_buggy_uci"
cat << EOF > "$MOCK_BUGGY_UCI"
#!/bin/sh
action="\$1"; shift || true
target="\${1:-}"
case "\$action" in
    get)
        exit 0
        ;;
    set)
        echo "BUGGY_SET: \$*" >> "$MOCK_BUGGY_UCI_LOG"
        exit 0
        ;;
    commit)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_BUGGY_UCI"

# 执行 cb41bda 的缺陷执行块（无视既有配置无差别覆写）
(
    SSID="OWRT"
    KEY="12345678"
    dev_idx=0
    while "$MOCK_BUGGY_UCI" get wireless.@wifi-device[$dev_idx] >/dev/null 2>&1; do
        "$MOCK_BUGGY_UCI" set wireless.@wifi-device[$dev_idx].disabled='0'
        "$MOCK_BUGGY_UCI" set wireless.@wifi-device[$dev_idx].country='CN'
        dev_idx=$((dev_idx + 1))
        [ $dev_idx -ge 2 ] && break
    done
    iface_idx=0
    while "$MOCK_BUGGY_UCI" get wireless.@wifi-iface[$iface_idx] >/dev/null 2>&1; do
        "$MOCK_BUGGY_UCI" set wireless.@wifi-iface[$iface_idx].ssid="$SSID"
        "$MOCK_BUGGY_UCI" set wireless.@wifi-iface[$iface_idx].encryption='psk2'
        "$MOCK_BUGGY_UCI" set wireless.@wifi-iface[$iface_idx].key="$KEY"
        iface_idx=$((iface_idx + 1))
        [ $iface_idx -ge 2 ] && break
    done
)

# 断言：已明确复现 cb41bda 的缺陷——无视用户既有配置，盲目注入默认 OWRT 与 12345678
if ! grep -q "wireless.@wifi-iface\[0\].ssid=OWRT" "$MOCK_BUGGY_UCI_LOG"; then
    echo "FAIL: Expected cb41bda logic to clobber user SSID with OWRT, but it did not!" >&2
    exit 1
fi
if ! grep -q "wireless.@wifi-iface\[0\].key=12345678" "$MOCK_BUGGY_UCI_LOG"; then
    echo "FAIL: Expected cb41bda logic to clobber user key with 12345678, but it did not!" >&2
    exit 1
fi
echo "PASS: Confirmed bug reproduction: cb41bda logic unconditionally overwrites existing custom WiFi with OWRT/12345678."

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
# 必须包含保留配置升级保护检查（阻止破坏既有无线配置）
if ! grep -q '\[ -s "$SYS_PREFIX/etc/config/wireless" \]' "$TARGET_DEFAULT_SCRIPT"; then
    echo "FAIL: 99-default-wifi missing sysupgrade keep-settings protection check!" >&2
    exit 1
fi
echo "PASS: Settings.sh generates valid, executable 99-default-wifi with sysupgrade protection."

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
# 4. 运行时模拟：验证全新刷机 (首次开机无既有配置) 时三频 WiFi 完整初始化
# -----------------------------------------------------------------------------
echo "--- Test 4: Simulate runtime fresh install first boot (no existing wireless config) ---"
SIM_ROOT="$TMP_DIR/sim_root"
mkdir -p "$SIM_ROOT/bin" "$SIM_ROOT/sbin" "$SIM_ROOT/etc/config" "$SIM_ROOT/etc/uci-defaults"

# 准备真实三频 AX6600 wireless 初始模板 (通过 mock /sbin/wifi config 动态生成，模拟首次开机硬件探测)
RAW_WIRELESS_TEMPLATE="$TMP_DIR/raw_wireless.txt"
cat << 'EOF' > "$RAW_WIRELESS_TEMPLATE"
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
        [ -f "$CONF" ] || exit 1
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

# Mock /sbin/wifi: 全新刷机时首次调用 wifi config 动态生成 raw wireless 配置
cat << EOF > "$SIM_ROOT/sbin/wifi"
#!/bin/sh
ROOT_DIR="\${SIM_ROOT:-}"
LOG_DIR="\${LOG_DIR:-\$ROOT_DIR/uci_log}"
mkdir -p "\$LOG_DIR"
echo "wifi \$*" >> "\$LOG_DIR/wifi_calls.log"
if [ "\$1" = "config" ]; then
    mkdir -p "\$ROOT_DIR/etc/config"
    cp "$RAW_WIRELESS_TEMPLATE" "\$ROOT_DIR/etc/config/wireless"
fi
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
echo "PASS: Runtime simulation verified fresh boot tri-band radio0/1/2 fully initialized with disabled=0, CN, OWRT, psk2, 12345678."

# -----------------------------------------------------------------------------
# 4b. 保留配置升级场景：验证已有自定义配置时 99-default-wifi 零修改绝对保护
# -----------------------------------------------------------------------------
echo "--- Test 4b: Simulate sysupgrade scenario: verify 99-default-wifi preserves existing user WiFi ---"
SIM_ROOT_UPGRADE="$TMP_DIR/sim_root_upgrade"
mkdir -p "$SIM_ROOT_UPGRADE/bin" "$SIM_ROOT_UPGRADE/sbin" "$SIM_ROOT_UPGRADE/etc/config" "$SIM_ROOT_UPGRADE/etc/uci-defaults"
mkdir -p "$TMP_DIR/upgrade_log"

# 用户已有自定义 WiFi 配置 (保留配置升级场景，已包含自定义频段、访客网络、SAE 加密、非默认信道)
cat << 'EOF' > "$SIM_ROOT_UPGRADE/etc/config/wireless"
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi'
	option channel '6'
	option band '2g'
	option htmode 'HE20'
	option disabled '0'
	option country 'US'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyCustomHome_2G'
	option encryption 'sae'
	option key 'SecretPass_99998888'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi+1'
	option channel '36'
	option band '5g'
	option htmode 'HE80'
	option disabled '0'
	option country 'US'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyCustomHome_5G'
	option encryption 'psk2'
	option key 'SecretPass_5G_Pro'

config wifi-device 'radio2'
	option type 'mac80211'
	option path 'platform/soc/c000000.wifi+2'
	option channel '149'
	option band '5g'
	option htmode 'HE160'
	option disabled '0'
	option country 'US'

config wifi-iface 'default_radio2'
	option device 'radio2'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyCustomHome_5G_Game'
	option encryption 'sae'
	option key 'SecretPass_Game_Ultra'

config wifi-iface 'guest_radio0'
	option device 'radio0'
	option network 'guest'
	option mode 'ap'
	option ssid 'Guest_WiFi_Free'
	option encryption 'none'
EOF

cp "$SIM_ROOT_UPGRADE/etc/config/wireless" "$SIM_ROOT_UPGRADE/etc/config/wireless.orig"

# 准备 Mock uci 与 Mock wifi (拦截并记录任何非法写操作)
cat << EOF > "$SIM_ROOT_UPGRADE/bin/uci"
#!/bin/sh
LOG_DIR="$TMP_DIR/upgrade_log"
mkdir -p "\$LOG_DIR"
echo "uci \$*" >> "\$LOG_DIR/uci_calls.log"
action=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        get|set|commit) action="\$1"; shift; break ;;
        *) shift ;;
    esac
done
case "\$action" in
    get) exit 0 ;;
    set) echo "UPGRADE_VIOLATION_SET: \$*" >> "\$LOG_DIR/unexpected_sets.log"; exit 0 ;;
    commit) echo "UPGRADE_VIOLATION_COMMIT: \$*" >> "\$LOG_DIR/unexpected_commit.log"; exit 0 ;;
esac
EOF
chmod +x "$SIM_ROOT_UPGRADE/bin/uci"

cat << EOF > "$SIM_ROOT_UPGRADE/sbin/wifi"
#!/bin/sh
LOG_DIR="$TMP_DIR/upgrade_log"
mkdir -p "\$LOG_DIR"
echo "UPGRADE_VIOLATION_WIFI: \$*" >> "\$LOG_DIR/unexpected_wifi.log"
exit 0
EOF
chmod +x "$SIM_ROOT_UPGRADE/sbin/wifi"

# 执行 99-default-wifi
UPGRADE_EXIT_CODE=0
(
    export SIM_ROOT="$SIM_ROOT_UPGRADE"
    export LOG_DIR="$TMP_DIR/upgrade_log"
    export PATH="$SIM_ROOT_UPGRADE/bin:$SIM_ROOT_UPGRADE/sbin:$PATH"
    sh "$TARGET_DEFAULT_SCRIPT"
) || UPGRADE_EXIT_CODE=$?

if [ "$UPGRADE_EXIT_CODE" -ne 0 ]; then
    echo "FAIL: 99-default-wifi exited with non-zero status ($UPGRADE_EXIT_CODE) during sysupgrade keep-settings!" >&2
    exit 1
fi

# 断言：严禁调用 uci set
if [ -f "$TMP_DIR/upgrade_log/unexpected_sets.log" ]; then
    echo "FAIL: 99-default-wifi executed forbidden 'uci set' during sysupgrade keep-settings!" >&2
    cat "$TMP_DIR/upgrade_log/unexpected_sets.log" >&2
    exit 1
fi

# 断言：严禁调用 uci commit
if [ -f "$TMP_DIR/upgrade_log/unexpected_commit.log" ]; then
    echo "FAIL: 99-default-wifi executed forbidden 'uci commit' during sysupgrade keep-settings!" >&2
    cat "$TMP_DIR/upgrade_log/unexpected_commit.log" >&2
    exit 1
fi

# 断言：严禁调用 wifi config
if [ -f "$TMP_DIR/upgrade_log/unexpected_wifi.log" ]; then
    echo "FAIL: 99-default-wifi executed forbidden 'wifi config' during sysupgrade keep-settings!" >&2
    cat "$TMP_DIR/upgrade_log/unexpected_wifi.log" >&2
    exit 1
fi

# 断言：用户的 wireless 配置文件逐字节完全保持一致
if ! cmp -s "$SIM_ROOT_UPGRADE/etc/config/wireless" "$SIM_ROOT_UPGRADE/etc/config/wireless.orig"; then
    echo "FAIL: User's wireless configuration file was modified during sysupgrade keep-settings!" >&2
    diff -u "$SIM_ROOT_UPGRADE/etc/config/wireless.orig" "$SIM_ROOT_UPGRADE/etc/config/wireless" >&2
    exit 1
fi

# 断言：用户配置中绝对未混入默认 OWRT 或 12345678
if grep -q "OWRT" "$SIM_ROOT_UPGRADE/etc/config/wireless" || grep -q "12345678" "$SIM_ROOT_UPGRADE/etc/config/wireless"; then
    echo "FAIL: Default credentials found in preserved wireless configuration!" >&2
    exit 1
fi
echo "PASS: Confirmed sysupgrade keep-settings 100% preserves user WiFi configuration (0 sets, 0 commits, 0 byte diff)."

# -----------------------------------------------------------------------------
# 4c. 保留配置极端边界演练：验证 0 字节无线配置（如掉电截断）同样被安全保护，绝不覆写
# -----------------------------------------------------------------------------
echo "--- Test 4c: Simulate truncated 0-byte wireless file under sysupgrade ---"
SIM_ROOT_EMPTY="$TMP_DIR/sim_root_empty"
mkdir -p "$SIM_ROOT_EMPTY/bin" "$SIM_ROOT_EMPTY/sbin" "$SIM_ROOT_EMPTY/etc/config" "$TMP_DIR/empty_log"
cp "$SIM_ROOT_UPGRADE/bin/uci" "$SIM_ROOT_EMPTY/bin/uci"
cp "$SIM_ROOT_UPGRADE/sbin/wifi" "$SIM_ROOT_EMPTY/sbin/wifi"
: > "$SIM_ROOT_EMPTY/etc/config/wireless"

EMPTY_EXIT_CODE=0
(
    export SIM_ROOT="$SIM_ROOT_EMPTY"
    export LOG_DIR="$TMP_DIR/empty_log"
    export PATH="$SIM_ROOT_EMPTY/bin:$SIM_ROOT_EMPTY/sbin:$PATH"
    sh "$TARGET_DEFAULT_SCRIPT"
) || EMPTY_EXIT_CODE=$?

if [ "$EMPTY_EXIT_CODE" -ne 0 ]; then
    echo "FAIL: 99-default-wifi did not exit cleanly (code $EMPTY_EXIT_CODE) on truncated wireless file!" >&2
    exit 1
fi
if [ -f "$TMP_DIR/empty_log/unexpected_sets.log" ]; then
    echo "FAIL: 99-default-wifi executed unexpected uci set on empty wireless file!" >&2
    exit 1
fi
if [ -f "$TMP_DIR/empty_log/unexpected_wifi.log" ]; then
    echo "FAIL: 99-default-wifi triggered forbidden wifi config on existing truncated wireless file!" >&2
    exit 1
fi
echo "PASS: Truncated 0-byte wireless file safely handled without triggering forbidden overwrite."

# -----------------------------------------------------------------------------
# 5. 边缘场景测试：无无线硬件/驱动未就绪时安全优雅退出 (code 0)
# -----------------------------------------------------------------------------
echo "--- Test 5: Verify missing wireless hardware/driver exits cleanly (code 0) ---"
SIM_ROOT2="$TMP_DIR/sim_root2"
mkdir -p "$SIM_ROOT2/bin" "$SIM_ROOT2/sbin" "$SIM_ROOT2/etc" "$SIM_ROOT2/etc/uci-defaults" "$TMP_DIR/uci_log2"
cp "$MOCK_UCI" "$SIM_ROOT2/bin/uci"

# Mock wifi: wifi config 执行但未探测到硬件，无 wireless 文件产生
cat << 'EOF' > "$SIM_ROOT2/sbin/wifi"
#!/bin/sh
ROOT_DIR="${SIM_ROOT:-}"
target_log="${LOG_DIR:-$ROOT_DIR/uci_log}/wifi_calls.log"
mkdir -p "$(dirname "$target_log")"
echo "wifi $*" >> "$target_log"
# 不创建 /etc/config/wireless，模拟无射频驱动/硬件
exit 0
EOF
chmod +x "$SIM_ROOT2/sbin/wifi"

TEST5_EXIT_CODE=0
(
    export SIM_ROOT="$SIM_ROOT2"
    export LOG_DIR="$TMP_DIR/uci_log2"
    export PATH="$SIM_ROOT2/bin:$SIM_ROOT2/sbin:$PATH"
    sh "$TARGET_DEFAULT_SCRIPT"
) || TEST5_EXIT_CODE=$?

if [ "$TEST5_EXIT_CODE" -ne 0 ]; then
    echo "FAIL: 99-default-wifi did not exit cleanly when no wireless hardware was present (code $TEST5_EXIT_CODE)!" >&2
    exit 1
fi
if ! grep -q "wifi config" "$TMP_DIR/uci_log2/wifi_calls.log"; then
    echo "FAIL: wifi config was not triggered when /etc/config/wireless was missing!" >&2
    exit 1
fi
echo "PASS: Missing wireless config properly triggers detection and exits cleanly when hardware absent."

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

SPECIAL_UC_DIR="$MOCK_BUILD_TREE_SPECIAL/package/network/config/wifi-scripts/files/lib/wifi"
mkdir -p "$SPECIAL_UC_DIR"
cat << 'EOF' > "$SPECIAL_UC_DIR/mac80211.uc"
let name = `default_${dev}`;
set wireless[name] = {
	device: dev,
	network: 'lan',
	mode: 'ap',
	ssid: 'OpenWrt',
	encryption: 'none'
};
EOF

cat << 'EOF' > "$SPECIAL_UC_DIR/mac80211.sh"
config wifi-device "$dev"
	option type 'mac80211'
	option channel 'auto'
	option disabled '1'

config wifi-iface "default_${dev}"
	option device "$dev"
	option ssid 'OpenWrt'
	option encryption 'none'
EOF

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

# 验证 mac80211.uc 模板特殊字符转义正确性（无 sed 报错，无 & 误展开，单引号合法转义）
if ! grep -q "encryption: 'psk2'" "$SPECIAL_UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc encryption was not updated to psk2 with special characters!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.uc" >&2
    exit 1
fi
if grep -q "encryption: 'none'" "$SPECIAL_UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc retained encryption none after patching with special characters!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -Fq "ssid: 'Athena/Home&5G\'Pro \$var'" "$SPECIAL_UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc SSID was not safely escaped with special characters!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.uc" >&2
    exit 1
fi

# 验证 mac80211.sh 模板特殊字符转义正确性
if ! grep -q "option encryption 'psk2'" "$SPECIAL_UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh encryption was not updated to psk2 with special characters!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if grep -q "option encryption 'none'" "$SPECIAL_UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh retained encryption none after patching with special characters!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option disabled '0'" "$SPECIAL_UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh disabled was not updated to 0!" >&2
    cat "$SPECIAL_UC_DIR/mac80211.sh" >&2
    exit 1
fi
echo "PASS: Extreme special characters in SSID and KEY parsed with 100% byte-for-byte fidelity and templates safely escaped."

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
# 8. 闪存磨损保护与 fstrim 定时调度架构归位验证
# -----------------------------------------------------------------------------
echo "--- Test 8: Verify fstrim flash wear leveling scheduler and initialization ---"
FSTRIM_INIT_FILE="$MOCK_BUILD_TREE/package/base-files/files/etc/init.d/fstrim"
FSTRIM_RCD_FILE="$MOCK_BUILD_TREE/package/base-files/files/etc/rc.d/S99fstrim"
FSTRIM_UCI_DEFAULT="$MOCK_BUILD_TREE/package/base-files/files/etc/uci-defaults/98-default-fstrim"
CUSTOM_KEEP_FILE="$MOCK_BUILD_TREE/package/base-files/files/lib/upgrade/keep.d/99-ax6600-custom"

# 8a: 前置复现验证：复现原 fstrim start 每次开机强行复活已被用户删除的 crontab 条目与无条件重启 cron
echo "--- Test 8a: Bug reproduction: prove legacy S99fstrim resurrects deleted crontabs and perturbs cron process ---"
BUG_CRON_DIR="$TMP_DIR/sim_bug_cron"
mkdir -p "$BUG_CRON_DIR/etc/crontabs" "$BUG_CRON_DIR/bin"
cat << 'EOF_MOCK_CRON' > "$BUG_CRON_DIR/bin/cron_mock"
#!/bin/sh
echo "$*" >> "$CRON_LOG"
exit 0
EOF_MOCK_CRON
chmod +x "$BUG_CRON_DIR/bin/cron_mock"

# 用户自主删除了 fstrim 任务，保留了其他自定义备份任务，或清空了 crontab
printf "30 2 * * * /usr/bin/my_backup.sh\n" > "$BUG_CRON_DIR/etc/crontabs/root"
export CRON_LOG="$BUG_CRON_DIR/cron_calls.log"
: > "$CRON_LOG"

# 模拟旧版 /etc/init.d/fstrim start 逻辑：无条件检查并在缺 fstrim 时强行追加，且无条件重启 cron
(
    CRON_FILE="$BUG_CRON_DIR/etc/crontabs/root"
    TRIM_ENTRY="0 4 * * 0 (/sbin/fstrim -av 2>&1 | logger -t fstrim)"
    if ! grep -q "fstrim" "$CRON_FILE"; then
        [ -n "$(tail -c 1 "$CRON_FILE" 2>/dev/null)" ] && echo "" >> "$CRON_FILE"
        echo "$TRIM_ENTRY" >> "$CRON_FILE"
    fi
    "$BUG_CRON_DIR/bin/cron_mock" enable
    "$BUG_CRON_DIR/bin/cron_mock" restart
)

# 断言：旧版逻辑无情破坏用户意图，复活了 fstrim 条目并触发了多余的 cron 杀进程重启
if ! grep -q "fstrim" "$BUG_CRON_DIR/etc/crontabs/root"; then
    echo "FAIL: Expected old logic to resurrect fstrim entry!" >&2
    exit 1
fi
if ! grep -q "restart" "$CRON_LOG"; then
    echo "FAIL: Expected old logic to restart cron!" >&2
    exit 1
fi
echo "PASS: Confirmed bug reproduction: legacy fstrim boot service unconditionally resurrects user-deleted crontab entries and restarts crond on every boot."

# 8b: 架构合规性验证：确认开机常驻软链接 S99fstrim 彻底移除，且 uci-defaults 脚本生成合规
echo "--- Test 8b: Architecture verification: S99fstrim symlink removed and uci-defaults created ---"
if [ -e "$FSTRIM_RCD_FILE" ]; then
    echo "FAIL: S99fstrim symlink ($FSTRIM_RCD_FILE) must NOT exist!" >&2
    exit 1
fi
if [ ! -x "$FSTRIM_UCI_DEFAULT" ]; then
    echo "FAIL: $FSTRIM_UCI_DEFAULT is missing or not executable!" >&2
    exit 1
fi
if [ ! -x "$FSTRIM_INIT_FILE" ]; then
    echo "FAIL: $FSTRIM_INIT_FILE is missing or not executable!" >&2
    exit 1
fi

sh -n "$FSTRIM_INIT_FILE" || { echo "FAIL: Syntax error in fstrim init script!"; exit 1; }
sh -n "$FSTRIM_UCI_DEFAULT" || { echo "FAIL: Syntax error in 98-default-fstrim!"; exit 1; }

# 8c: 构建期 IPKG_INSTROOT 防护断言：返回 1 阻止 rootfs 构建时提前删除
echo "--- Test 8c: Verify 98-default-fstrim rootfs build-time IPKG_INSTROOT protection ---"
set +e
IPKG_INSTROOT="$TMP_DIR/mock_instroot" sh "$FSTRIM_UCI_DEFAULT" >/dev/null 2>&1
INSTROOT_EXIT=$?
set -e
if [ "$INSTROOT_EXIT" -ne 1 ]; then
    echo "FAIL: 98-default-fstrim must exit 1 under IPKG_INSTROOT (actual: $INSTROOT_EXIT)!" >&2
    exit 1
fi
echo "PASS: Build-time protection verified (exit 1 preserves script in rootfs for target first boot)."

# 8d: 运行时全新刷机 / 恢复出厂设置场景模拟（无既有 crontab）
echo "--- Test 8d: Simulate fresh install / factory reset first boot ---"

# 8d-1: /sbin/fstrim 存在场景：必须精准解析为 /sbin/fstrim，且必须启动 cron
SIM_FSTRIM_FRESH="$TMP_DIR/sim_fstrim_fresh"
mkdir -p "$SIM_FSTRIM_FRESH/bin" "$SIM_FSTRIM_FRESH/sbin" "$SIM_FSTRIM_FRESH/etc/init.d"
printf "#!/bin/sh\nexit 0\n" > "$SIM_FSTRIM_FRESH/sbin/fstrim" && chmod +x "$SIM_FSTRIM_FRESH/sbin/fstrim"
cat << EOF > "$SIM_FSTRIM_FRESH/bin/logger"
#!/bin/sh
exit 0
EOF
chmod +x "$SIM_FSTRIM_FRESH/bin/logger"
cat << EOF > "$SIM_FSTRIM_FRESH/etc/init.d/cron"
#!/bin/sh
echo "\$*" >> "$SIM_FSTRIM_FRESH/cron_fresh.log"
exit 0
EOF
chmod +x "$SIM_FSTRIM_FRESH/etc/init.d/cron"

(
    export PATH="$SIM_FSTRIM_FRESH/bin:$SIM_FSTRIM_FRESH/sbin:$PATH"
    SIM_ROOT="$SIM_FSTRIM_FRESH" sh "$FSTRIM_UCI_DEFAULT"
)
FRESH_EXIT=$?
if [ "$FRESH_EXIT" -ne 0 ]; then
    echo "FAIL: 98-default-fstrim failed on fresh install (exit: $FRESH_EXIT)!" >&2
    exit 1
fi

CRON_FRESH_FILE="$SIM_FSTRIM_FRESH/etc/crontabs/root"
if [ ! -f "$CRON_FRESH_FILE" ]; then
    echo "FAIL: 98-default-fstrim did not create crontab file on fresh install!" >&2
    exit 1
fi
if ! grep -q "/sbin/fstrim" "$CRON_FRESH_FILE"; then
    echo "FAIL: Expected /sbin/fstrim in crontab when /sbin/fstrim exists, got: $(cat "$CRON_FRESH_FILE")" >&2
    exit 1
fi
if ! grep -q "restart" "$SIM_FSTRIM_FRESH/cron_fresh.log"; then
    echo "FAIL: cron was not started on fresh install!" >&2
    exit 1
fi

# 8d-2: 仅 /usr/sbin/fstrim 存在场景：必须精准解析为 /usr/sbin/fstrim
SIM_FSTRIM_USR="$TMP_DIR/sim_fstrim_usr"
mkdir -p "$SIM_FSTRIM_USR/bin" "$SIM_FSTRIM_USR/usr/sbin" "$SIM_FSTRIM_USR/etc/init.d"
printf "#!/bin/sh\nexit 0\n" > "$SIM_FSTRIM_USR/usr/sbin/fstrim" && chmod +x "$SIM_FSTRIM_USR/usr/sbin/fstrim"
cp "$SIM_FSTRIM_FRESH/bin/logger" "$SIM_FSTRIM_USR/bin/logger"
(
    export PATH="$SIM_FSTRIM_USR/bin:$PATH"
    SIM_ROOT="$SIM_FSTRIM_USR" sh "$FSTRIM_UCI_DEFAULT"
)
if ! grep -q "/usr/sbin/fstrim" "$SIM_FSTRIM_USR/etc/crontabs/root"; then
    echo "FAIL: Expected /usr/sbin/fstrim in crontab when /usr/sbin/fstrim exists, got: $(cat "$SIM_FSTRIM_USR/etc/crontabs/root")" >&2
    exit 1
fi

# 8d-3: 二进制文件缺失场景：安全回退为 bare fstrim
SIM_FSTRIM_NONE="$TMP_DIR/sim_fstrim_none"
mkdir -p "$SIM_FSTRIM_NONE/bin" "$SIM_FSTRIM_NONE/etc/init.d"
cp "$SIM_FSTRIM_FRESH/bin/logger" "$SIM_FSTRIM_NONE/bin/logger"
(
    export PATH="$SIM_FSTRIM_NONE/bin:$PATH"
    SIM_ROOT="$SIM_FSTRIM_NONE" sh "$FSTRIM_UCI_DEFAULT"
)
if ! grep -E -q "\(fstrim -av" "$SIM_FSTRIM_NONE/etc/crontabs/root"; then
    echo "FAIL: Expected bare fstrim fallback in crontab when binary not found, got: $(cat "$SIM_FSTRIM_NONE/etc/crontabs/root")" >&2
    exit 1
fi

# 8d-4: 沙箱边界测试：SYS_PREFIX 指定但缺少 init.d/cron 时，绝不污染调用宿主 /etc/init.d/cron
SIM_FSTRIM_ISOLATE="$TMP_DIR/sim_fstrim_isolate"
mkdir -p "$SIM_FSTRIM_ISOLATE/bin"
cp "$SIM_FSTRIM_FRESH/bin/logger" "$SIM_FSTRIM_ISOLATE/bin/logger"
(
    export PATH="$SIM_FSTRIM_ISOLATE/bin:$PATH"
    SIM_ROOT="$SIM_FSTRIM_ISOLATE" sh "$FSTRIM_UCI_DEFAULT"
)
ISOLATE_EXIT=$?
if [ "$ISOLATE_EXIT" -ne 0 ]; then
    echo "FAIL: 98-default-fstrim failed under isolated root (exit: $ISOLATE_EXIT)!" >&2
    exit 1
fi
echo "PASS: Fresh install scenario verified: fstrim path resolution (/sbin, /usr/sbin, fallback) and cron activation."

# 8e: 运行时保留配置升级场景模拟（已有 crontab：0 字节差异，绝不篡改，绝不重启 cron）
echo "--- Test 8e: Simulate sysupgrade keep-settings scenario (100% untouched crontab) ---"
SIM_FSTRIM_PRESERVE="$TMP_DIR/sim_fstrim_preserve"
mkdir -p "$SIM_FSTRIM_PRESERVE/bin" "$SIM_FSTRIM_PRESERVE/etc/crontabs" "$SIM_FSTRIM_PRESERVE/etc/init.d"
USER_CRON_CONTENT="30 2 * * * /usr/bin/my_nightly_backup.sh"
printf "%s\n" "$USER_CRON_CONTENT" > "$SIM_FSTRIM_PRESERVE/etc/crontabs/root"
PRESERVE_CRON_FILE="$SIM_FSTRIM_PRESERVE/etc/crontabs/root"
ORIG_HASH=$(sha256sum "$PRESERVE_CRON_FILE" | awk '{print $1}')
ORIG_SIZE=$(wc -c < "$PRESERVE_CRON_FILE")

cat << EOF > "$SIM_FSTRIM_PRESERVE/etc/init.d/cron"
#!/bin/sh
echo "FORBIDDEN_CALL: \$*" >> "$SIM_FSTRIM_PRESERVE/cron_forbidden.log"
exit 0
EOF
chmod +x "$SIM_FSTRIM_PRESERVE/etc/init.d/cron"

(
    export PATH="$SIM_FSTRIM_PRESERVE/bin:$PATH"
    SIM_ROOT="$SIM_FSTRIM_PRESERVE" sh "$FSTRIM_UCI_DEFAULT"
)
PRESERVE_EXIT=$?
if [ "$PRESERVE_EXIT" -ne 0 ]; then
    echo "FAIL: 98-default-fstrim failed on preserved upgrade (exit: $PRESERVE_EXIT)!" >&2
    exit 1
fi

NEW_HASH=$(sha256sum "$PRESERVE_CRON_FILE" | awk '{print $1}')
NEW_SIZE=$(wc -c < "$PRESERVE_CRON_FILE")

if [ "$ORIG_HASH" != "$NEW_HASH" ] || [ "$ORIG_SIZE" -ne "$NEW_SIZE" ]; then
    echo "FAIL: Preserved user crontab was modified during sysupgrade!" >&2
    diff -u <(echo "$USER_CRON_CONTENT") "$PRESERVE_CRON_FILE" >&2 || true
    exit 1
fi
if grep -q "fstrim" "$PRESERVE_CRON_FILE"; then
    echo "FAIL: fstrim was erroneously injected into preserved user crontab!" >&2
    exit 1
fi
if [ -f "$SIM_FSTRIM_PRESERVE/cron_forbidden.log" ]; then
    echo "FAIL: cron service was touched during preserved upgrade: $(cat "$SIM_FSTRIM_PRESERVE/cron_forbidden.log")" >&2
    exit 1
fi

# 8e-2: 用户配置了 0 字节空 crontab 文件场景（已删除全部任务）
SIM_EMPTY_ROOT="$TMP_DIR/sim_empty_cron"
mkdir -p "$SIM_EMPTY_ROOT/etc/crontabs"
touch "$SIM_EMPTY_ROOT/etc/crontabs/root"
(
    SIM_ROOT="$SIM_EMPTY_ROOT" sh "$FSTRIM_UCI_DEFAULT"
)
if [ -s "$SIM_EMPTY_ROOT/etc/crontabs/root" ]; then
    echo "FAIL: Empty crontab was unexpectedly written to!" >&2
    exit 1
fi

# 8e-3: 用户配置了自定义外部/软链 crontab 场景（指向外部或挂载介质上的定时任务）
SIM_SYMLINK_ROOT="$TMP_DIR/sim_symlink_cron"
mkdir -p "$SIM_SYMLINK_ROOT/etc/crontabs" "$SIM_SYMLINK_ROOT/mnt/sda1"
USER_LINK_CONTENT="0 1 * * * /mnt/sda1/ext_backup.sh"
printf "%s\n" "$USER_LINK_CONTENT" > "$SIM_SYMLINK_ROOT/mnt/sda1/custom_cron"
ln -sf "$SIM_SYMLINK_ROOT/mnt/sda1/custom_cron" "$SIM_SYMLINK_ROOT/etc/crontabs/root" 2>/dev/null || cp "$SIM_SYMLINK_ROOT/mnt/sda1/custom_cron" "$SIM_SYMLINK_ROOT/etc/crontabs/root"
HAD_SYMLINK=0
[ -L "$SIM_SYMLINK_ROOT/etc/crontabs/root" ] && HAD_SYMLINK=1

(
    SIM_ROOT="$SIM_SYMLINK_ROOT" sh "$FSTRIM_UCI_DEFAULT"
)
if [ $HAD_SYMLINK -eq 1 ] && [ ! -L "$SIM_SYMLINK_ROOT/etc/crontabs/root" ]; then
    echo "FAIL: Symlink crontab was replaced with regular file!" >&2
    exit 1
fi
if [ "$(cat "$SIM_SYMLINK_ROOT/etc/crontabs/root")" != "$USER_LINK_CONTENT" ]; then
    echo "FAIL: Target of custom crontab was modified!" >&2
    exit 1
fi
echo "PASS: Preserved upgrade scenario verified: user crontab 100% unchanged (0-byte diff, empty file, symlink, 0 cron calls)."

# 8f: 手动触发 /etc/init.d/fstrim start 验证：仅执行 trim，绝不修改 crontabs 或重启 cron
echo "--- Test 8f: Verify manual /etc/init.d/fstrim start execution safety ---"
MANUAL_ROOT="$TMP_DIR/sim_manual_fstrim"
mkdir -p "$MANUAL_ROOT/bin" "$MANUAL_ROOT/etc/crontabs"
cat << EOF > "$MANUAL_ROOT/bin/logger"
#!/bin/sh
echo "\$*" >> "$MANUAL_ROOT/logger.log"
exit 0
EOF
chmod +x "$MANUAL_ROOT/bin/logger"
cat << EOF > "$MANUAL_ROOT/bin/fstrim"
#!/bin/sh
echo "TRIMMED" >> "$MANUAL_ROOT/trimmed.log"
exit 0
EOF
chmod +x "$MANUAL_ROOT/bin/fstrim"

printf "45 1 * * * /bin/custom.sh\n" > "$MANUAL_ROOT/etc/crontabs/root"
(
    export PATH="$MANUAL_ROOT/bin:$PATH"
    sh -c ". '$FSTRIM_INIT_FILE' && start"
)
if [ ! -f "$MANUAL_ROOT/trimmed.log" ]; then
    echo "FAIL: Manual fstrim start did not invoke fstrim command!" >&2
    exit 1
fi
if grep -q "fstrim" "$MANUAL_ROOT/etc/crontabs/root"; then
    echo "FAIL: Manual fstrim start altered crontab file!" >&2
    exit 1
fi
echo "PASS: Manual fstrim start safely executes trim without altering crontabs or service states."

# 8g: 预置 keep.d 资产保护文件生成校验
echo "--- Test 8g: Verify Settings.sh creates package/base-files/files/lib/upgrade/keep.d/99-ax6600-custom ---"
if [ ! -f "$CUSTOM_KEEP_FILE" ]; then
    echo "FAIL: $CUSTOM_KEEP_FILE was not created by Settings.sh!" >&2
    exit 1
fi
for req_path in "/etc/docker/daemon.json" "/etc/adguardhome.yaml" "/root/.ssh/"; do
    if ! grep -Fxq "$req_path" "$CUSTOM_KEEP_FILE"; then
        echo "FAIL: $CUSTOM_KEEP_FILE missing declared path $req_path!" >&2
        exit 1
    fi
done
echo "PASS: 99-ax6600-custom keep.d whitelist correctly generated with all required non-UCI assets."

# -----------------------------------------------------------------------------
# 9. 现代 ucode 模板 (mac80211.uc) 与经典 shell 模板 (mac80211.sh) 原生修改验证
# -----------------------------------------------------------------------------
echo "--- Test 9: Verify mac80211.uc and mac80211.sh template modification when present ---"
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

cat << 'EOF' > "$UC_DIR/mac80211.sh"
config wifi-device "$dev"
	option type 'mac80211'
	option channel 'auto'
	option band '2g'
	option htmode 'HE20'
	option disabled '1'

config wifi-iface "default_${dev}"
	option device "$dev"
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'none'
EOF

(
    cd "$MOCK_BUILD_TREE_UC"
    export WRT_SSID="Athena_Modern_WiFi"
    export WRT_WORD="Secret_Password_888"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

# 验证 mac80211.uc 模板
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

# 验证 mac80211.sh 模板
if ! grep -q "option ssid 'Athena_Modern_WiFi'" "$UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh ssid was not updated to Athena_Modern_WiFi!" >&2
    cat "$UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option encryption 'psk2'" "$UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh encryption was not updated to psk2!" >&2
    cat "$UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option key 'Secret_Password_888'" "$UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh key was not updated to Secret_Password_888!" >&2
    cat "$UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option disabled '0'" "$UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh disabled was not updated to 0!" >&2
    cat "$UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option country 'CN'" "$UC_DIR/mac80211.sh"; then
    echo "FAIL: mac80211.sh country was not set to CN!" >&2
    cat "$UC_DIR/mac80211.sh" >&2
    exit 1
fi
echo "PASS: mac80211.uc and mac80211.sh templates successfully updated with default credentials."

# -----------------------------------------------------------------------------
# 10. 经典与上游无引号语法及 ImmortalWrt 变体模板修改验证
# -----------------------------------------------------------------------------
echo "--- Test 10: Verify unquoted mac80211.sh (upstream default) and variant templates ---"
MOCK_BUILD_TREE_UPSTREAM="$TMP_DIR/mock_wrt_upstream"
UPSTREAM_UC_DIR="$MOCK_BUILD_TREE_UPSTREAM/package/network/config/wifi-scripts/files/lib/wifi"
mkdir -p "$UPSTREAM_UC_DIR"
mkdir -p "$MOCK_BUILD_TREE_UPSTREAM/package/base-files/files/bin"
mkdir -p "$MOCK_BUILD_TREE_UPSTREAM/package/base-files/files/etc"
touch "$MOCK_BUILD_TREE_UPSTREAM/package/base-files/files/bin/config_generate"
touch "$MOCK_BUILD_TREE_UPSTREAM/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_BUILD_TREE_UPSTREAM/.config"

# 上游原生无单引号 mac80211.sh 模板（常见于 OpenWrt 官方 detect_mac80211）
cat << 'EOF' > "$UPSTREAM_UC_DIR/mac80211.sh"
config wifi-device  radio$devidx
	option type     mac80211
	option channel  ${channel}
	option hwmode   11${mode_band}
	option path	'${dev_path}'
	option htmode	$htmode
	option disabled 1

config wifi-iface default_radio$devidx
	option device   radio$devidx
	option network  lan
	option mode     ap
	option ssid     ImmortalWrt
	option encryption none
EOF

# 双引号及带逗号 mac80211.uc 模板
cat << 'EOF' > "$UPSTREAM_UC_DIR/mac80211.uc"
let name = `default_${dev}`;
set wireless[name] = {
	device: dev,
	network: "lan",
	mode: "ap",
	ssid: "ImmortalWrt",
	encryption: "none"
};
set wireless[dev] = {
	type: 'mac80211',
	disabled: 1,
};
EOF

(
    cd "$MOCK_BUILD_TREE_UPSTREAM"
    export WRT_SSID="Upstream_Athena_WiFi"
    export WRT_WORD="Password_98765432"
    export WRT_TARGET="QUALCOMMAX"
    export WRT_CONFIG="IPQ60XX-WIFI-YES"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

# 验证无引号 mac80211.sh 模板被成功替换
if ! grep -q "option ssid 'Upstream_Athena_WiFi'" "$UPSTREAM_UC_DIR/mac80211.sh"; then
    echo "FAIL: Unquoted mac80211.sh ssid was not updated!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option encryption 'psk2'" "$UPSTREAM_UC_DIR/mac80211.sh"; then
    echo "FAIL: Unquoted mac80211.sh encryption was not updated to psk2!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option key 'Password_98765432'" "$UPSTREAM_UC_DIR/mac80211.sh"; then
    echo "FAIL: Unquoted mac80211.sh key was not set!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option disabled '0'" "$UPSTREAM_UC_DIR/mac80211.sh"; then
    echo "FAIL: Unquoted mac80211.sh disabled was not updated to 0!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.sh" >&2
    exit 1
fi
if ! grep -q "option country 'CN'" "$UPSTREAM_UC_DIR/mac80211.sh"; then
    echo "FAIL: Unquoted mac80211.sh country was not set to CN!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.sh" >&2
    exit 1
fi

# 验证双引号 mac80211.uc 模板被成功替换
if ! grep -q "ssid: 'Upstream_Athena_WiFi'" "$UPSTREAM_UC_DIR/mac80211.uc"; then
    echo "FAIL: Double-quoted mac80211.uc ssid was not updated!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -q "encryption: 'psk2'" "$UPSTREAM_UC_DIR/mac80211.uc"; then
    echo "FAIL: Double-quoted mac80211.uc encryption was not updated to psk2!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -q "key: 'Password_98765432'" "$UPSTREAM_UC_DIR/mac80211.uc"; then
    echo "FAIL: Double-quoted mac80211.uc key was not set!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.uc" >&2
    exit 1
fi
if ! grep -q "disabled: 0" "$UPSTREAM_UC_DIR/mac80211.uc"; then
    echo "FAIL: mac80211.uc disabled was not updated to 0!" >&2
    cat "$UPSTREAM_UC_DIR/mac80211.uc" >&2
    exit 1
fi
echo "PASS: Upstream unquoted shell and double-quoted ucode templates successfully updated."

echo "================================================================================"
echo "=== All Athena AX6600 WiFi Default Config Tests Passed Successfully! ==="
echo "================================================================================"
exit 0
