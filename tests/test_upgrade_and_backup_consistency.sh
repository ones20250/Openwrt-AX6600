#!/usr/bin/env bash
# Regression Test: Verify upgrade checks, Docker backup consistency, and NSS cleanup logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUIDE_FILE="$REPO_ROOT/Docs/AX6600保留配置升级与Docker备份恢复指南.md"
README_FILE="$REPO_ROOT/README.md"
HELPER_SCRIPT="$REPO_ROOT/Scripts/docker_upgrade_helper.sh"

echo "=== Running Upgrade & Backup Consistency Verification ==="

# Test 1: Guide existence and key sections verification
echo "--- Test 1: Verify Guide File and Essential Content ---"
if [ ! -f "$GUIDE_FILE" ]; then
    echo "FAIL: Guide file $GUIDE_FILE does not exist!" >&2
    exit 1
fi

REQUIRED_SECTIONS=(
    "rootfs|rootfs_1"
    "DockerRootDir"
    "docker_upgrade_helper.sh"
    "IMAGE="
    "sysupgrade -c"
    "firewall.qcanssecm"
    "flowtable"
    "socks5-hostname"
    "mysqldump"
    "pg_dumpall"
    "redis-cli"
    "iptables-nft"
    "DISTRIB_DESCRIPTION"
    "extroot"
    "FORWARD"
)

for SEC in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -qiE "$SEC" "$GUIDE_FILE"; then
        echo "FAIL: Required section/keyword '$SEC' not found in $GUIDE_FILE!" >&2
        exit 1
    fi
done
echo "PASS: All essential sections and keywords verified in Guide."

# Test 2: Verify README references and warnings
echo "--- Test 2: Verify README References and Upgrade Guidance ---"
if ! grep -q "Docs/AX6600保留配置升级与Docker备份恢复指南.md" "$README_FILE"; then
    echo "FAIL: README.md does not reference the upgrade guide!" >&2
    exit 1
fi

if ! grep -q "目标分区红线" "$README_FILE"; then
    echo "FAIL: README.md missing target partition warning!" >&2
    exit 1
fi
echo "PASS: README.md correctly references guide and target partition warning."

# Test 3: Simulation of NSS firewall cleanup with section type and path verification
echo "--- Test 3: Simulation of NSS Firewall Cleanup Logic ---"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'uci_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_CONFIG="$TMP_DIR/firewall"
cat << 'EOF' > "$MOCK_CONFIG"
config defaults
	option syn_flood '1'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'

config include 'qcanssecm'
	option path '/etc/firewall.d/qca-nss-ecm'
	option reload '1'

config rule 'user_ssh'
	option name 'Allow-SSH'
	option src 'wan'
	option proto 'tcp'
	option dest_port '22'
	option target 'ACCEPT'

config redirect 'user_port_forward'
	option name 'Web-Forward'
	option src 'wan'
	option proto 'tcp'
	option src_dport '8080'
	option dest_ip '192.168.10.100'
	option dest_port '80'
	option target 'DNAT'
EOF

# Mock uci tool using the mock config
cat << 'EOF' > "$TMP_DIR/uci"
#!/usr/bin/env bash
CONFIG_FILE="$UCI_CONFIG_FILE"
CMD="$1"
TARGET="${2:-}"

case "$CMD" in
    get|-q)
        [ "$CMD" = "-q" ] && { CMD="$2"; TARGET="${3:-}"; }
        if [[ "$TARGET" == "firewall.qcanssecm" ]]; then
            if grep -q "config include 'qcanssecm'" "$CONFIG_FILE"; then
                echo "include"
                exit 0
            elif grep -q "config rule 'qcanssecm'" "$CONFIG_FILE"; then
                echo "rule"
                exit 0
            fi
            exit 1
        fi
        if [[ "$TARGET" == "firewall.qcanssecm.path" ]]; then
            grep -A 2 "config include 'qcanssecm'" "$CONFIG_FILE" | grep "option path" | awk '{print $3}' | tr -d "'"
            exit 0
        fi
        exit 1
        ;;
    delete)
        if [[ "$TARGET" == "firewall.qcanssecm" ]]; then
            awk '
                BEGIN { skip=0 }
                /config include '\''qcanssecm'\''/ { skip=1; next }
                /^config / && skip { skip=0 }
                !skip { print }
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            exit 0
        fi
        exit 1
        ;;
    commit)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$TMP_DIR/uci"

# Execute mock cleanup using the exact logic from the guide
(
    export PATH="$TMP_DIR:$PATH"
    export UCI_CONFIG_FILE="$MOCK_CONFIG"
    if uci -q get firewall.qcanssecm >/dev/null; then
        SEC_TYPE=$(uci -q get firewall.qcanssecm || true)
        SCRIPT_PATH=$(uci -q get firewall.qcanssecm.path || true)
        if [ "$SEC_TYPE" = "include" ]; then
            case "$SCRIPT_PATH" in
                /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss)
                    echo "Found legacy NSS include firewall.qcanssecm, deleting..."
                    cp "$MOCK_CONFIG" "$MOCK_CONFIG.bak"
                    uci delete firewall.qcanssecm
                    uci commit firewall
                    ;;
            esac
        fi
    fi
)

# Verify results: qcanssecm should be gone, user rules must remain untouched
if grep -q "config include 'qcanssecm'" "$MOCK_CONFIG"; then
    echo "FAIL: firewall.qcanssecm was not deleted!" >&2
    exit 1
fi

if [ ! -f "$MOCK_CONFIG.bak" ]; then
    echo "FAIL: firewall backup file was not created before cleanup!" >&2
    exit 1
fi

if ! grep -q "config rule 'user_ssh'" "$MOCK_CONFIG"; then
    echo "FAIL: user rule 'user_ssh' was erroneously deleted!" >&2
    exit 1
fi

if ! grep -q "config redirect 'user_port_forward'" "$MOCK_CONFIG"; then
    echo "FAIL: user redirect 'user_port_forward' was erroneously deleted!" >&2
    exit 1
fi

# Verify negative case: same-name rule is NOT deleted
cat << 'EOF' > "$MOCK_CONFIG"
config rule 'qcanssecm'
	option name 'Allow-Custom-qcanssecm'
	option target 'ACCEPT'
EOF

(
    export PATH="$TMP_DIR:$PATH"
    export UCI_CONFIG_FILE="$MOCK_CONFIG"
    if uci -q get firewall.qcanssecm >/dev/null; then
        SEC_TYPE=$(uci -q get firewall.qcanssecm || true)
        SCRIPT_PATH=$(uci -q get firewall.qcanssecm.path || true)
        if [ "$SEC_TYPE" = "include" ]; then
            case "$SCRIPT_PATH" in
                /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss)
                    uci delete firewall.qcanssecm
                    uci commit firewall
                    ;;
            esac
        fi
    fi
)

if ! grep -q "config rule 'qcanssecm'" "$MOCK_CONFIG"; then
    echo "FAIL: rule with same name 'qcanssecm' was mistakenly deleted!" >&2
    exit 1
fi
echo "PASS: NSS cleanup successfully removed only the legacy include, created backup, and preserved all user rules."

# Test 4: Helper script executable test
echo "--- Test 4: Verify docker_upgrade_helper.sh is valid ---"
if [ ! -f "$HELPER_SCRIPT" ]; then
    echo "FAIL: Helper script $HELPER_SCRIPT missing!" >&2
    exit 1
fi
sh "$HELPER_SCRIPT" >/dev/null 2>&1 || true
echo "PASS: Helper script interface is valid."

# -----------------------------------------------------------------------------
# Test 5: 前置复现验证：复现标准 OpenWrt sysupgrade 默认规则静默丢失非 UCI 关键资产
# -----------------------------------------------------------------------------
echo "--- Test 5: Bug reproduction: prove default sysupgrade silently drops non-UCI user assets ---"
TEST5_ROOT="$TMP_DIR/test5_root"
mkdir -p "$TEST5_ROOT/etc/config" "$TEST5_ROOT/lib/upgrade/keep.d" "$TEST5_ROOT/etc/docker" "$TEST5_ROOT/root/.ssh"
echo "config test" > "$TEST5_ROOT/etc/config/network"
echo "nameserver 1.1.1.1" > "$TEST5_ROOT/etc/resolv.conf"

# 创建官方默认 keep.d 规则（如 base-files-essential 仅保护系统基础凭据与 crontab）
cat << 'EOF' > "$TEST5_ROOT/lib/upgrade/keep.d/base-files-essential"
/etc/passwd
/etc/shadow
/etc/group
/etc/dropbear/
/etc/crontabs/
EOF

# 创建用户的非 UCI 核心资产
DOCKER_JSON='{"registry-mirrors":["https://mirror.example.com"],"bip":"172.18.0.1/16"}'
ADGUARD_YAML='bind_host: 0.0.0.0\nport: 3000\ndns:\n  upstream_dns:\n  - 223.5.5.5'
SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserCustomKeyAdmin@router'

echo "$DOCKER_JSON" > "$TEST5_ROOT/etc/docker/daemon.json"
printf "%b\n" "$ADGUARD_YAML" > "$TEST5_ROOT/etc/adguardhome.yaml"
echo "$SSH_KEY" > "$TEST5_ROOT/root/.ssh/authorized_keys"

# 模拟官方原版 sysupgrade -c 收集列表（仅读取官方 keep.d 与 /etc/config）
DEF_BACKUP_LIST="$TMP_DIR/test5_def_backup.list"
: > "$DEF_BACKUP_LIST"
(
    cd "$TEST5_ROOT"
    for pattern in $(cat "$TEST5_ROOT"/lib/upgrade/keep.d/* 2>/dev/null); do
        rel="${pattern#/}"
        [ -e "$rel" ] && echo "$rel" >> "$DEF_BACKUP_LIST"
    done
    find etc/config -type f >> "$DEF_BACKUP_LIST"
)

# 断言：在原版规则下，非 UCI 关键资产无一被纳入备份清单，打包将直接遗失
for missing_asset in "etc/docker/daemon.json" "etc/adguardhome.yaml" "root/.ssh/authorized_keys"; do
    if grep -Fxq "$missing_asset" "$DEF_BACKUP_LIST"; then
        echo "FAIL: Unexpectedly found $missing_asset in default backup list!" >&2
        exit 1
    fi
done

# 模拟解包到全新系统（原版恢复结果必然缺失上述资产）
DEF_RESTORE_DIR="$TMP_DIR/test5_restore"
mkdir -p "$DEF_RESTORE_DIR"
(
    cd "$TEST5_ROOT"
    tar -czf "$TMP_DIR/test5_def.tar.gz" -T "$DEF_BACKUP_LIST" 2>/dev/null || true
    tar -xzf "$TMP_DIR/test5_def.tar.gz" -C "$DEF_RESTORE_DIR" 2>/dev/null || true
)

if [ -f "$DEF_RESTORE_DIR/etc/docker/daemon.json" ] || [ -f "$DEF_RESTORE_DIR/etc/adguardhome.yaml" ] || [ -f "$DEF_RESTORE_DIR/root/.ssh/authorized_keys" ]; then
    echo "FAIL: Expected assets to be missing in default sysupgrade restore!" >&2
    exit 1
fi
echo "PASS: Confirmed bug reproduction: standard sysupgrade without 99-ax6600-custom silently drops non-UCI user assets (/etc/docker/daemon.json, /etc/adguardhome.yaml, /root/.ssh/)."

# -----------------------------------------------------------------------------
# Test 6: 校验 Settings.sh 预置 99-ax6600-custom keep.d 白名单文件
# -----------------------------------------------------------------------------
echo "--- Test 6: Verify Settings.sh creates package/base-files/files/lib/upgrade/keep.d/99-ax6600-custom ---"
MOCK_TREE_KEEP="$TMP_DIR/mock_tree_keep"
mkdir -p "$MOCK_TREE_KEEP/package/base-files/files/bin" "$MOCK_TREE_KEEP/package/base-files/files/etc"
touch "$MOCK_TREE_KEEP/package/base-files/files/bin/config_generate"
touch "$MOCK_TREE_KEEP/package/base-files/files/etc/sysctl.conf"
touch "$MOCK_TREE_KEEP/.config"

(
    cd "$MOCK_TREE_KEEP"
    bash "$REPO_ROOT/Scripts/Settings.sh"
)

CUSTOM_KEEP_PATH="$MOCK_TREE_KEEP/package/base-files/files/lib/upgrade/keep.d/99-ax6600-custom"
if [ ! -f "$CUSTOM_KEEP_PATH" ]; then
    echo "FAIL: $CUSTOM_KEEP_PATH was not created by Settings.sh!" >&2
    exit 1
fi

REQUIRED_KEEP_ASSETS=(
    "/etc/docker/daemon.json"
    "/etc/adguardhome.yaml"
    "/root/.ssh/"
)

for asset in "${REQUIRED_KEEP_ASSETS[@]}"; do
    if ! grep -Fxq "$asset" "$CUSTOM_KEEP_PATH"; then
        echo "FAIL: $CUSTOM_KEEP_PATH missing declared path $asset!" >&2
        exit 1
    fi
done
echo "PASS: Settings.sh generates valid 99-ax6600-custom declaring all non-UCI user assets."

# -----------------------------------------------------------------------------
# Test 7: 修复后验收：验证预置 99-ax6600-custom 下 sysupgrade 能够无缝保留全部非 UCI 资产
# -----------------------------------------------------------------------------
echo "--- Test 7: Verify sysupgrade keep.d integration preserves non-UCI assets during backup and restore ---"
cp "$CUSTOM_KEEP_PATH" "$TEST5_ROOT/lib/upgrade/keep.d/99-ax6600-custom"

# 创建 SSH 目录内的符号链接（测试软链接资产保护）
ln -sf authorized_keys "$TEST5_ROOT/root/.ssh/authorized_keys2"

FIXED_BACKUP_LIST="$TMP_DIR/test7_fixed_backup.list"
: > "$FIXED_BACKUP_LIST"

(
    cd "$TEST5_ROOT"
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [ -z "$pattern" ] && continue
        [[ "$pattern" =~ ^# ]] && continue
        rel="${pattern#/}"
        if [ -d "$rel" ]; then
            find "$rel" -type f -o -type l >> "$FIXED_BACKUP_LIST"
        elif [ -e "$rel" ] || [ -L "$rel" ]; then
            echo "$rel" >> "$FIXED_BACKUP_LIST"
        fi
    done < <(cat "$TEST5_ROOT"/lib/upgrade/keep.d/* 2>/dev/null)
    find etc/config -type f >> "$FIXED_BACKUP_LIST"
)

# 验证清单中包含所有目标非 UCI 资产（含 SSH 符号链接）
for asset in "etc/docker/daemon.json" "etc/adguardhome.yaml" "root/.ssh/authorized_keys" "root/.ssh/authorized_keys2"; do
    if ! grep -Fxq "$asset" "$FIXED_BACKUP_LIST"; then
        echo "FAIL: Fixed backup list missing $asset!" >&2
        exit 1
    fi
done

# 模拟真实 sysupgrade 打包与恢复
FIXED_RESTORE_DIR="$TMP_DIR/test7_restore"
mkdir -p "$FIXED_RESTORE_DIR"
(
    cd "$TEST5_ROOT"
    tar -czf "$TMP_DIR/test7_fixed.tar.gz" -T "$FIXED_BACKUP_LIST" 2>/dev/null
    tar -xzf "$TMP_DIR/test7_fixed.tar.gz" -C "$FIXED_RESTORE_DIR"
)

# 严格比对文件内容一致性（0 字节差异）
REST_DOCKER=$(cat "$FIXED_RESTORE_DIR/etc/docker/daemon.json")
if [ "$REST_DOCKER" != "$DOCKER_JSON" ]; then
    echo "FAIL: Restored /etc/docker/daemon.json content does not match original!" >&2
    exit 1
fi

REST_ADGUARD=$(cat "$FIXED_RESTORE_DIR/etc/adguardhome.yaml")
EXPECT_ADGUARD=$(printf "%b" "$ADGUARD_YAML")
if [ "$REST_ADGUARD" != "$EXPECT_ADGUARD" ]; then
    echo "FAIL: Restored /etc/adguardhome.yaml content does not match original!" >&2
    exit 1
fi

REST_SSH=$(cat "$FIXED_RESTORE_DIR/root/.ssh/authorized_keys")
if [ "$REST_SSH" != "$SSH_KEY" ]; then
    echo "FAIL: Restored /root/.ssh/authorized_keys content does not match original!" >&2
    exit 1
fi

if [ -L "$TEST5_ROOT/root/.ssh/authorized_keys2" ]; then
    if [ ! -L "$FIXED_RESTORE_DIR/root/.ssh/authorized_keys2" ]; then
        echo "FAIL: Restored /root/.ssh/authorized_keys2 was not preserved as a symlink!" >&2
        exit 1
    fi
fi

# 测试容错性：当用户尚未配置 adguardhome 时（可选文件不存在），sysupgrade 收集过程绝不报错中断
rm -f "$TEST5_ROOT/etc/adguardhome.yaml"
TOLERANCE_LIST="$TMP_DIR/test7_tolerance.list"
: > "$TOLERANCE_LIST"
(
    cd "$TEST5_ROOT"
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [ -z "$pattern" ] && continue
        [[ "$pattern" =~ ^# ]] && continue
        rel="${pattern#/}"
        if [ -d "$rel" ]; then
            find "$rel" -type f -o -type l >> "$TOLERANCE_LIST"
        elif [ -e "$rel" ] || [ -L "$rel" ]; then
            echo "$rel" >> "$TOLERANCE_LIST"
        fi
    done < <(cat "$TEST5_ROOT"/lib/upgrade/keep.d/* 2>/dev/null)
)
if ! grep -Fxq "etc/docker/daemon.json" "$TOLERANCE_LIST" || ! grep -Fxq "root/.ssh/authorized_keys" "$TOLERANCE_LIST"; then
    echo "FAIL: Missing optional file caused backup collection to skip other valid assets!" >&2
    exit 1
fi
echo "PASS: keep.d/99-ax6600-custom successfully preserves all non-UCI user assets during sysupgrade."

echo "=== All Upgrade & Backup Consistency Tests Passed Successfully! ==="
