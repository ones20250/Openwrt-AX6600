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

escape_sed() {
	local str="$1"
	str="${str//\\/\\\\}"
	str="${str//&/\\&}"
	str="${str//\//\\/}"
	printf '%s' "$str"
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
if [ -n "$WRT_IP" ]; then
	SAFE_WRT_IP=$(escape_sed "$WRT_IP")
	apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$SAFE_WRT_IP/g"
fi
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

# =========================================================
# WiFi 默认配置与安全加固：
# 1. 兼容现代 ucode 模板 (mac80211.uc) 与经典 shell 模板 (mac80211.sh)，源码构建期原生植入默认配置
# 2. 注入 uci-defaults 脚本 (99-default-wifi)，仅在全新刷机/无既有配置时生效，保留配置升级绝不破坏用户既有配置
# =========================================================
TARGET_SSID="${WRT_SSID:-OWRT}"
TARGET_WORD="${WRT_WORD:-12345678}"

escape_ucode_str() {
	local str="$1"
	str="${str//\\/\\\\}"
	str="${str//\'/\\\'}"
	printf '%s' "$str"
}

escape_sh_uci_str() {
	local str="$1"
	if [[ "$str" == *"'"* ]]; then
		str="${str//\\/\\\\}"
		str="${str//\"/\\\"}"
		str="${str//\$/\\\$}"
		printf '"%s"' "$str"
	else
		printf "'%s'" "$str"
	fi
}

patch_wifi_template() {
	local TPL="$1"
	[ -f "$TPL" ] || return 0
	if [[ "$TPL" == *".uc" ]]; then
		local safe_ssid safe_key
		safe_ssid=$(escape_sed "$(escape_ucode_str "$TARGET_SSID")")
		safe_key=$(escape_sed "$(escape_ucode_str "$TARGET_WORD")")
		sed -i "s/ssid: ['\"][^'\"]*['\"]/ssid: '$safe_ssid'/g" "$TPL" 2>/dev/null || true
		sed -i "s/encryption: ['\"]none['\"]/encryption: 'psk2',\n\t\tkey: '$safe_key'/g" "$TPL" 2>/dev/null || true
		sed -i "s/disabled:[[:space:]]*1/disabled: 0,\n\t\tcountry: 'CN'/g" "$TPL" 2>/dev/null || true
	elif [[ "$TPL" == *".sh" ]]; then
		local safe_ssid safe_key
		safe_ssid=$(escape_sed "$(escape_sh_uci_str "$TARGET_SSID")")
		safe_key=$(escape_sed "$(escape_sh_uci_str "$TARGET_WORD")")
		sed -i "s/option disabled ['\"]\?1['\"]\?/option disabled '0'\n\t\toption country 'CN'/g" "$TPL" 2>/dev/null || true
		sed -i "s/option ssid ['\"]\?[^'\"]*['\"]\?/option ssid $safe_ssid/g" "$TPL" 2>/dev/null || true
		sed -i "s/option encryption ['\"]\?none['\"]\?/option encryption 'psk2'\n\t\toption key $safe_key/g" "$TPL" 2>/dev/null || true
	fi
}

MATCH_TPLS=$(find ./package ./feeds -type f \( -name "mac80211.sh" -o -name "mac80211.uc" \) 2>/dev/null || true)
if [ -n "$MATCH_TPLS" ]; then
	while IFS= read -r match_tpl; do
		[ -n "$match_tpl" ] && patch_wifi_template "$match_tpl"
	done <<< "$MATCH_TPLS"
else
	WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
	patch_wifi_template "$WIFI_UC"
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

# 检查是否为保留配置升级 (sysupgrade) 或系统已存在既有无线配置：
# 在保留配置升级场景下，/etc/config/wireless 会在系统启动前被 sysupgrade 备份还原。
# 出厂默认值（OWRT / 12345678）仅供全新刷机或恢复出厂设置（无既有无线配置）首次使用，
# 严禁篡改或覆盖用户的自定义 SSID、密码、加密协议及射频参数！
if [ -s "$SYS_PREFIX/etc/config/wireless" ] || [ -f "$SYS_PREFIX/etc/config/wireless" ]; then
	exit 0
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

# 全新刷机 / 恢复出厂设置场景：调用 wifi config 探测并生成初始无线配置
"$WIFI_CMD" config 2>/dev/null || true

[ -s "$SYS_PREFIX/etc/config/wireless" ] || exit 0

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
# 闪存寿命与存储保护：合规初始化每周 fstrim 定时调度 (防止高频 Docker 磨损 eMMC)
# 架构归位说明：
# 1. 彻底移除开机常驻自启软链接 (/etc/rc.d/S99fstrim)，杜绝每次开机强行复活用户已删除的任务与杀进程重启 cron
# 2. 将出厂定时任务初始化归位至标准 uci-defaults 脚本 (98-default-fstrim)
#    - 构建期 (IPKG_INSTROOT)：退出 1 阻断构建阶段提前删除，随 rootfs 下发
#    - 运行期保留配置升级：检测到既有 /etc/crontabs/root 时严格静默退出 0，不破坏用户既有配置与 cron 状态
#    - 运行期全新安装/恢复出厂：仅在无既有配置时写入默认每周 trim 任务并启动 cron，执行后由系统自动销毁 (rm -f)
# 3. 提供纯净的手动执行脚本 (/etc/init.d/fstrim)，仅负责触发文件系统 trim，绝不越权篡改 crontab 或重启 cron
# =========================================================
INIT_DIR="./package/base-files/files/etc/init.d"
RCD_DIR="./package/base-files/files/etc/rc.d"
mkdir -p "$INIT_DIR" "$RCD_DIR"

FSTRIM_INIT="$INIT_DIR/fstrim"
cat << 'EOF_FSTRIM' > "$FSTRIM_INIT"
#!/bin/sh /etc/rc.common
# Weekly fstrim manual service for Athena AX6600 eMMC flash wear leveling

START=99

start() {
	TRIM_CMD="/sbin/fstrim"
	if [ -x "/sbin/fstrim" ]; then
		TRIM_CMD="/sbin/fstrim"
	elif [ -x "/usr/sbin/fstrim" ]; then
		TRIM_CMD="/usr/sbin/fstrim"
	else
		TRIM_CMD="fstrim"
	fi
	$TRIM_CMD -av 2>&1 | logger -t fstrim
}
EOF_FSTRIM
chmod +x "$FSTRIM_INIT"

# 严格确保开机常驻自启软链接 (S99fstrim) 不存在，绝不在构建期或开机时常驻自启
rm -f "$RCD_DIR/S99fstrim"

DEFAULT_FSTRIM_SCRIPT="$WIFI_DEFAULTS_DIR/98-default-fstrim"
cat << 'EOF_FSTRIM_UCI' > "$DEFAULT_FSTRIM_SCRIPT"
#!/bin/sh
# 98-default-fstrim: Athena AX6600 (JDCloud RE-CS-02) Default fstrim Cron Initialization

SYS_PREFIX="${IPKG_INSTROOT:-${SIM_ROOT:-}}"

# 1. 在 rootfs 构建期 (IPKG_INSTROOT)：
# 必须退出非 0 状态以阻断 rootfs 构建阶段提前删除 (rm -f) 本初始化脚本，确保随 rootfs 下发并在目标机首次开机时执行。
if [ -n "$IPKG_INSTROOT" ]; then
	exit 1
fi

CRON_DIR="$SYS_PREFIX/etc/crontabs"
CRON_FILE="$CRON_DIR/root"

# 2. 检查是否为保留配置升级 (sysupgrade) 或系统已存在既有定时任务配置：
# 若检测到 /etc/crontabs/root 已存在（保留配置升级场景，包括用户已自定义修改或主动删除 trim 任务，含符号链接）：
# 严格保持静默，直接退出 0，绝不篡改用户既有定时任务，绝不触发多余的 cron 杀进程重启！
# 退出 0 后由 OpenWrt 官方 uci-defaults 机制将其自动销毁 (rm -f)，后续绝不反复运行。
if [ -e "$CRON_FILE" ] || [ -L "$CRON_FILE" ]; then
	exit 0
fi

# 3. 仅在全新刷机 / 恢复出厂设置（无既有 /etc/crontabs/root）时，创建默认每周 trim 任务并启动 cron
mkdir -p "$CRON_DIR"

if [ -n "$SYS_PREFIX" ]; then
	if [ -x "$SYS_PREFIX/sbin/fstrim" ]; then
		TRIM_CMD="/sbin/fstrim"
	elif [ -x "$SYS_PREFIX/usr/sbin/fstrim" ]; then
		TRIM_CMD="/usr/sbin/fstrim"
	else
		TRIM_CMD="fstrim"
	fi
else
	if [ -x "/sbin/fstrim" ]; then
		TRIM_CMD="/sbin/fstrim"
	elif [ -x "/usr/sbin/fstrim" ]; then
		TRIM_CMD="/usr/sbin/fstrim"
	else
		TRIM_CMD="fstrim"
	fi
fi

cat << EOF > "$CRON_FILE"
0 4 * * 0 ($TRIM_CMD -av 2>&1 | logger -t fstrim)
EOF
chmod 600 "$CRON_FILE" 2>/dev/null || true

CRON_INIT="/etc/init.d/cron"
if [ -n "$SYS_PREFIX" ]; then
	CRON_INIT="$SYS_PREFIX/etc/init.d/cron"
fi
if [ -x "$CRON_INIT" ]; then
	"$CRON_INIT" enable 2>/dev/null || true
	"$CRON_INIT" restart 2>/dev/null || true
fi

exit 0
EOF_FSTRIM_UCI
chmod +x "$DEFAULT_FSTRIM_SCRIPT"

# =========================================================
# DoH 加密 DNS 代理初始化（待命模式）：
# 1. 源码层原生置换：扫描并重写 ./package 与 ./feeds 下的 https-dns-proxy.config 与 https-dns-proxy.conf
# 2. 源码层 init 脚本加固：离线构建期阻断 prepare_rootfs 生成开机自启软链接，杜绝 SquashFS ROM 天生携带自启链接
# 3. 严格保护 sysupgrade 保留配置升级场景：只要既有配置存在，100% 保持用户配置与启停状态，绝不篡改重写
# 4. 注入 uci-defaults 脚本 (97-default-https-dns-proxy)：仅在全新出厂刷机且无配置文件时预置国内合规待命模板 (DNSPod/AliDNS)
# =========================================================

# 1. 源码层原生置换配置文件模板 (Source-Level Native Template Patching)：
# 扫描并直接重写 ./package 与 ./feeds 下的 https-dns-proxy.config 与 https-dns-proxy.conf，
# 将纯净的国内合规待命模板预置到源码树，切断 upstream 海外节点与 53 端口强制劫持污染。
HDP_SOURCE_FILES=$(find ./package ./feeds -type f \( -name "https-dns-proxy.config" -o -name "https-dns-proxy.conf" \) 2>/dev/null || true)
if [ -n "$HDP_SOURCE_FILES" ]; then
	while IFS= read -r hdp_tpl; do
		[ -n "$hdp_tpl" ] || continue
		cat << 'EOF_HDP_SRC' > "$hdp_tpl"
config main 'config'
	option dnsmasq_config_update '*'
	option force_dns '0'

config https-dns-proxy 'dnspod'
	option bootstrap_dns '119.29.29.29,223.5.5.5'
	option resolver_url 'https://doh.pub/dns-query'
	option listen_addr '127.0.0.1'
	option listen_port '5053'

config https-dns-proxy 'alidns'
	option bootstrap_dns '223.5.5.5,119.29.29.29'
	option resolver_url 'https://dns.alidns.com/dns-query'
	option listen_addr '127.0.0.1'
	option listen_port '5054'
EOF_HDP_SRC
	done <<< "$HDP_SOURCE_FILES"
fi

# 2. 源码层 init 脚本启动策略加固 (Source-Level Init Service Patching)：
# 针对离线 rootfs 构建阶段 (IPKG_INSTROOT 非空)，将 START/STOP 置空，彻底阻断 OpenWrt prepare_rootfs 自动生成自启软链接；
# 在路由器运行期 (IPKG_INSTROOT 为空)，START=80 / STOP=10 正常生效，保障用户在 Web 页面按需启用/禁用功能完全正常。
HDP_INIT_FILES=$(find ./package ./feeds -type f -name "https-dns-proxy.init" 2>/dev/null || true)
if [ -n "$HDP_INIT_FILES" ]; then
	while IFS= read -r hdp_init; do
		[ -n "$hdp_init" ] || continue
		if ! grep -q "IPKG_INSTROOT" "$hdp_init" 2>/dev/null; then
			sed -i -E 's/^[[:space:]]*START=([0-9]+)/[ -n "$IPKG_INSTROOT" ] \&\& START="" || START=\1/' "$hdp_init"
			sed -i -E 's/^[[:space:]]*STOP=([0-9]+)/[ -n "$IPKG_INSTROOT" ] \&\& STOP="" || STOP=\1/' "$hdp_init"
		fi
	done <<< "$HDP_INIT_FILES"
fi

DEFAULT_HDP_SCRIPT="$WIFI_DEFAULTS_DIR/97-default-https-dns-proxy"
cat << 'EOF_HDP_UCI' > "$DEFAULT_HDP_SCRIPT"
#!/bin/sh
# 97-default-https-dns-proxy: Athena AX6600 (JDCloud RE-CS-02) Standby DoH Configuration

SYS_PREFIX="${IPKG_INSTROOT:-${SIM_ROOT:-}}"

# 1. 在 rootfs 构建期 (IPKG_INSTROOT)：
# 清理构建期残留自启软链接，退出非 0 状态阻断构建阶段提前删除本脚本，确保随 rootfs 下发并在目标机首次开机时执行。
if [ -n "$IPKG_INSTROOT" ]; then
	rm -f "$IPKG_INSTROOT/etc/rc.d/"*https-dns-proxy 2>/dev/null || true
	exit 1
fi

CFG_FILE="$SYS_PREFIX/etc/config/https-dns-proxy"
INIT_FILE="$SYS_PREFIX/etc/init.d/https-dns-proxy"

# 2. 检查是否为保留配置升级 (sysupgrade) 或用户既有配置：
# 存在即信任原则 (Trust Existing Configuration)：
# 只要既有配置文件存在且非空，100% 认定为合法用户配置或保留升级资产，
# 立即静默退出 (exit 0)，绝对不进行任何启发式扫描，绝对不篡改重写，绝对不触碰服务状态！
if [ -s "$CFG_FILE" ]; then
	exit 0
fi

# 3. 仅在全新刷机 / 出厂初始化（配置文件完全不存在或为空）时，预置国内待命模板并确保禁用状态：
# a. 确保服务开机默认处于禁用状态（待命模式），绝不默认接管 dnsmasq 上游与劫持 53 端口
if [ -x "$INIT_FILE" ]; then
	"$INIT_FILE" stop 2>/dev/null || true
	"$INIT_FILE" disable 2>/dev/null || true
fi
rm -f "$SYS_PREFIX/etc/rc.d/"*https-dns-proxy 2>/dev/null || true

# b. 写入国内合规且防端口劫持死锁的优质 DoH 模板（默认不开启）
mkdir -p "$SYS_PREFIX/etc/config"
cat << 'EOF_HDP' > "$CFG_FILE"
config main 'config'
	option dnsmasq_config_update '*'
	option force_dns '0'

config https-dns-proxy 'dnspod'
	option bootstrap_dns '119.29.29.29,223.5.5.5'
	option resolver_url 'https://doh.pub/dns-query'
	option listen_addr '127.0.0.1'
	option listen_port '5053'

config https-dns-proxy 'alidns'
	option bootstrap_dns '223.5.5.5,119.29.29.29'
	option resolver_url 'https://dns.alidns.com/dns-query'
	option listen_addr '127.0.0.1'
	option listen_port '5054'
EOF_HDP

exit 0
EOF_HDP_UCI
chmod +x "$DEFAULT_HDP_SCRIPT"

# =========================================================
# 系统升级与资产保护：预置 keep.d 白名单，防止保留配置升级时静默丢失应用级非 UCI 用户资产
# 覆盖关键资产：/etc/docker/daemon.json, /etc/adguardhome.yaml, /root/.ssh/
# 架构底线：严禁在 keep.d 中加入 /etc/rc.d/ 系统服务软链接，彻底杜绝保留配置升级引发的 procd 启动队列竞争与状态失控
# =========================================================
KEEP_DIR="./package/base-files/files/lib/upgrade/keep.d"
mkdir -p "$KEEP_DIR"

CUSTOM_KEEP_FILE="$KEEP_DIR/99-ax6600-custom"
cat << 'EOF_KEEP' > "$CUSTOM_KEEP_FILE"
/etc/docker/daemon.json
/etc/adguardhome.yaml
/root/.ssh/
EOF_KEEP
chmod 644 "$CUSTOM_KEEP_FILE"

CFG_FILE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
	#修改默认IP地址
	if [ -n "$WRT_IP" ]; then
		SAFE_WRT_IP=$(escape_sed "$WRT_IP")
		sed -i "s/192\.168\.[0-9]*\.[0-9]*/$SAFE_WRT_IP/g" "$CFG_FILE"
	fi
	#修改默认主机名
	if [ -n "$WRT_NAME" ]; then
		SAFE_WRT_NAME=$(escape_sed "$WRT_NAME")
		sed -i "s/hostname='.*'/hostname='$SAFE_WRT_NAME'/g" "$CFG_FILE"
	fi
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
