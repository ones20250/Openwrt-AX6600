#!/bin/bash

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

# =========================================================
# WiFi 默认配置与安全加固：
# 1. 兼容现代 ucode 模板 (mac80211.uc)，若源码中存在则同步写入默认配置
# 2. 注入 uci-defaults 脚本 (99-default-wifi)，确保三频首次冷启动合规生效
# =========================================================
TARGET_SSID="${WRT_SSID:-OWRT}"
TARGET_WORD="${WRT_WORD:-12345678}"

WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	# 兼容现代 ucode 语法模板修改默认 SSID 与加密 (针对 mac80211.uc)
	sed -i "s/ssid: '[^']*'/ssid: '$TARGET_SSID'/g" "$WIFI_UC" 2>/dev/null || true
	sed -i "s/encryption: 'none'/encryption: 'psk2',\n\t\tkey: '$TARGET_WORD'/g" "$WIFI_UC" 2>/dev/null || true
fi

WIFI_DEFAULTS_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$WIFI_DEFAULTS_DIR"

DEFAULT_WIFI_SCRIPT="$WIFI_DEFAULTS_DIR/99-default-wifi"
cat << 'EOF_WIFI_HEAD' > "$DEFAULT_WIFI_SCRIPT"
#!/bin/sh
# 99-default-wifi: Athena AX6600 (JDCloud RE-CS-02) Default Wi-Fi Configuration

SYS_PREFIX="${IPKG_INSTROOT:-${SIM_ROOT:-}}"

EOF_WIFI_HEAD

# 使用 printf %q 安全写入 SSID 与 KEY，彻底杜绝任何特殊字符引起的 sed 替换损坏或 shell 语法错误
printf 'SSID=%q\nKEY=%q\n\n' "$TARGET_SSID" "$TARGET_WORD" >> "$DEFAULT_WIFI_SCRIPT"

cat << 'EOF_WIFI_BODY' >> "$DEFAULT_WIFI_SCRIPT"
# 在 rootfs 构建期 (IPKG_INSTROOT)：
# 目标机物理射频硬件尚未探测，无线配置尚未就绪。
# 必须退出非 0 状态以阻断 rootfs 构建阶段提前删除 (rm -f) 本初始化脚本，确保刷机后首次冷启动正常执行。
if [ -n "$IPKG_INSTROOT" ]; then
	[ -f "$IPKG_INSTROOT/etc/config/wireless" ] || exit 1
fi

WIFI_CMD="/sbin/wifi"
if [ -n "$SYS_PREFIX" ] && [ -x "$SYS_PREFIX/sbin/wifi" ]; then
	WIFI_CMD="$SYS_PREFIX/sbin/wifi"
elif ! [ -x "$WIFI_CMD" ]; then
	if command -v wifi >/dev/null 2>&1; then
		WIFI_CMD="wifi"
	else
		exit 0
	fi
fi

if [ ! -f "$SYS_PREFIX/etc/config/wireless" ]; then
	"$WIFI_CMD" config 2>/dev/null || true
fi

[ -f "$SYS_PREFIX/etc/config/wireless" ] || exit 0

UCI_CMD="uci"
if [ -n "$SYS_PREFIX" ]; then
	UCI_CMD="uci -c $SYS_PREFIX/etc/config"
fi
# 配置三频物理射频设备 (radio0/1/2): 启用并设置国家码 CN
dev_idx=0
while $UCI_CMD -q get wireless.@wifi-device[$dev_idx] >/dev/null; do
	$UCI_CMD -q set wireless.@wifi-device[$dev_idx].disabled='0'
	$UCI_CMD -q set wireless.@wifi-device[$dev_idx].country='CN'
	dev_idx=$((dev_idx + 1))
done

# 配置三频无线 AP 接口 (radio0/1/2): SSID、WPA2-PSK 加密与密码
iface_idx=0
while $UCI_CMD -q get wireless.@wifi-iface[$iface_idx] >/dev/null; do
	$UCI_CMD -q set wireless.@wifi-iface[$iface_idx].ssid="$SSID"
	$UCI_CMD -q set wireless.@wifi-iface[$iface_idx].encryption='psk2'
	$UCI_CMD -q set wireless.@wifi-iface[$iface_idx].key="$KEY"
	iface_idx=$((iface_idx + 1))
done

# 兼容命名接口段配置 (default_radio0/1/2)
for r in 0 1 2; do
	if $UCI_CMD -q get wireless.radio${r} >/dev/null; then
		$UCI_CMD -q set wireless.radio${r}.disabled='0'
		$UCI_CMD -q set wireless.radio${r}.country='CN'
	fi
	if $UCI_CMD -q get wireless.default_radio${r} >/dev/null; then
		$UCI_CMD -q set wireless.default_radio${r}.ssid="$SSID"
		$UCI_CMD -q set wireless.default_radio${r}.encryption='psk2'
		$UCI_CMD -q set wireless.default_radio${r}.key="$KEY"
	fi
done

$UCI_CMD commit wireless
exit 0
EOF_WIFI_BODY

chmod +x "$DEFAULT_WIFI_SCRIPT"

# =========================================================
# 闪存寿命与存储保护：注入每周 fstrim 定时调度 (防止高频 Docker 磨损 eMMC)
# =========================================================
INIT_DIR="./package/base-files/files/etc/init.d"
RCD_DIR="./package/base-files/files/etc/rc.d"
mkdir -p "$INIT_DIR" "$RCD_DIR"

FSTRIM_INIT="$INIT_DIR/fstrim"
cat << 'EOF_FSTRIM' > "$FSTRIM_INIT"
#!/bin/sh /etc/rc.common
# Weekly fstrim cron scheduler for Athena AX6600 eMMC flash wear leveling

START=99

start() {
	CRON_DIR="/etc/crontabs"
	CRON_FILE="$CRON_DIR/root"
	TRIM_CMD="/sbin/fstrim"
	[ -x "$TRIM_CMD" ] || TRIM_CMD="/usr/sbin/fstrim"
	[ -x "$TRIM_CMD" ] || TRIM_CMD="fstrim"
	TRIM_ENTRY="0 4 * * 0 ($TRIM_CMD -av 2>&1 | logger -t fstrim)"

	mkdir -p "$CRON_DIR"
	if [ ! -f "$CRON_FILE" ]; then
		echo "$TRIM_ENTRY" > "$CRON_FILE"
	elif ! grep -q "fstrim" "$CRON_FILE"; then
		echo "$TRIM_ENTRY" >> "$CRON_FILE"
	fi
	/etc/init.d/cron enable 2>/dev/null || true
	/etc/init.d/cron restart 2>/dev/null || true
}
EOF_FSTRIM
chmod +x "$FSTRIM_INIT"

# 构建期直接预置开机自启软链接 (S99fstrim)，保证 rootfs 烧写后开机自启生效
ln -sf ../init.d/fstrim "$RCD_DIR/S99fstrim"

DEFAULT_FSTRIM_SCRIPT="$WIFI_DEFAULTS_DIR/98-default-fstrim"
cat << 'EOF_FSTRIM_UCI' > "$DEFAULT_FSTRIM_SCRIPT"
#!/bin/sh
SYS_PREFIX="${IPKG_INSTROOT:-${SIM_ROOT:-}}"
if [ -n "$SYS_PREFIX" ]; then
	mkdir -p "$SYS_PREFIX/etc/rc.d"
	ln -sf ../init.d/fstrim "$SYS_PREFIX/etc/rc.d/S99fstrim" 2>/dev/null || true
	exit 0
fi

if [ -x /etc/init.d/fstrim ]; then
	/etc/init.d/fstrim enable 2>/dev/null || true
	/etc/init.d/fstrim start 2>/dev/null || true
fi
exit 0
EOF_FSTRIM_UCI
chmod +x "$DEFAULT_FSTRIM_SCRIPT"

CFG_FILE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
	#修改默认IP地址
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
	#修改默认主机名
	sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#私有扩展配置注入
if [ -n "$GITHUB_WORKSPACE" ] && [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
elif [ -f "./Config/PRIVATE.txt" ]; then
	cat "./Config/PRIVATE.txt" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		if [ -d "$DTS_PATH" ]; then
			find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
			echo "qualcommax set up nowifi successfully!"
		fi
	fi
fi

# =========================================================
# 智能系统调优：优化内存水位线 (min_free_kbytes)
# =========================================================

MIN_FREE_VAL=16384
CONF_FILE="./package/base-files/files/etc/sysctl.conf"

if [ -f "$CONF_FILE" ]; then
	# 提取当前值（只匹配非注释、行首）
	CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

	if [ -z "$CURRENT_VAL" ]; then
		echo "" >> "$CONF_FILE"
		echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
		echo "Memory patch: value not found, added $MIN_FREE_VAL."
	else
		if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
			sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
			echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
		else
			echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
		fi
	fi
fi
