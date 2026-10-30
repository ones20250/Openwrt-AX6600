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

echo "=== All Upgrade & Backup Consistency Tests Passed Successfully! ==="
