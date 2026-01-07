#!/bin/bash

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

# =========================================================
# 3. 核心依赖修复与报错规避 (暴力补丁)
# =========================================================

echo "Starting automated fix for dependencies and errors..."

# 3.1 修正 python3-pysocks / unidecode 缺失警告 (解决 onionshare-cli 报错)
# 直接移除找不到的依赖，防止 make defconfig 中断
find ./feeds/packages/ -name "Makefile" | xargs grep -E -l "python3-(pysocks|unidecode)" | xargs -r \
    sed -i -E 's/python3-(pysocks|unidecode)//g'

# 3.2 破碎递归依赖环 (Recursive dependency Fix)
# 将导致死循环的 'select' 属性改为 'depends on'
# 针对 OpenSSL
if [ -f package/libs/openssl/Config.in ]; then
    sed -i 's/select PACKAGE_libopenssl/depends on PACKAGE_libopenssl/g' package/libs/openssl/Config.in
fi

# 针对 iptasn 对 perl 的强制依赖
find ./ -name "Makefile" | xargs grep -l "PACKAGE_iptasn" | xargs -r \
    sed -i 's/select PACKAGE_perl/depends on PACKAGE_perl/g'

# 3.3 修正驱动名错误 (针对 diskman 等插件)
# 修正 ntfs33 -> ntfs3
find ./ -name "Makefile" | xargs grep -l "kmod-fs-ntfs33" | xargs -r \
    sed -i 's/kmod-fs-ntfs33/kmod-fs-ntfs3/g'

# 3.4 修正 QModem 依赖 (可选，防止其导致编译失败)
if [ -d "package/qmodem" ]; then
    find package/qmodem -name "Makefile" | xargs -r \
        sed -i -E 's/kmod-mhi-wwan|quectel-CM-5G//g'
fi

# =========================================================
# 4. 强制清理缓存并写入配置
# =========================================================

# 清理 Kconfig 缓存 (至关重要)
rm -rf tmp

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#开启sqm-nss插件
	echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
	echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi
