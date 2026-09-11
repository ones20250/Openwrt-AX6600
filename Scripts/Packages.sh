#!/bin/bash

# 安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}

	echo " "
	for NAME in "${PKG_LIST[@]}"; do
		echo "Search directory: $NAME"
		local FOUND_DIRS
		FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"

	local PKG_COMMIT
	PKG_COMMIT=$(git -C "$REPO_NAME" rev-parse --short HEAD 2>/dev/null || echo unknown)
	if [ -n "$GITHUB_WORKSPACE" ]; then
		echo "$PKG_NAME $PKG_REPO $PKG_BRANCH $PKG_COMMIT" >> "$GITHUB_WORKSPACE/package-versions.txt"
	fi

	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find "./$REPO_NAME"/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf "./$REPO_NAME/"
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f "$REPO_NAME" "$PKG_NAME"
	fi
}

# 第三方主题
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "main"

# JDC AX6600 Athena LED：仓库包含 athena-led + luci-app-athena-led 两个 OpenWrt 包
UPDATE_PACKAGE "athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "main" "pkg"
UPDATE_PACKAGE "luci-app-athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "main" "pkg"

# Bandix Plus：前端与后端分别来自两个仓库
UPDATE_PACKAGE "bandix-plus" "timsaya/openwrt-bandix-plus" "main" "pkg"
UPDATE_PACKAGE "luci-app-bandix-plus" "timsaya/luci-app-bandix-plus" "main" "pkg"

# dae / daed / LuCI：从同一仓库提取对应包
UPDATE_PACKAGE "dae" "kenzok8/openwrt-daede" "main" "pkg"
UPDATE_PACKAGE "daed" "kenzok8/openwrt-daede" "main" "pkg"
UPDATE_PACKAGE "luci-app-daede" "kenzok8/openwrt-daede" "main" "pkg"

# Podman LuCI 管理面板。仓库根目录本身就是 OpenWrt 包，不使用 pkg 模式。
UPDATE_PACKAGE "luci-app-podman" "Zerogiven-OpenWRT-Packages/luci-app-podman" "main"

# DNS：mosdns LuCI/运行时；smartdns/dnsmasq 使用当前 OpenWrt feed 的兼容版本。
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"

if [[ "${WRT_PROFILE^^}" == "PLUS" ]]; then
	UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "master" "pkg"
	UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"
	UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
	UPDATE_PACKAGE "viking" "ones20250/packages" "main" "" "luci-app-timewol luci-app-wolplus"
fi

# 更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"
	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" $PKG_FILE)
		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")
		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")
		local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")
		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
		local NEW_URL=$(echo $PKG_URL | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
		local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)
		echo "old version: $OLD_VER $OLD_HASH"
		echo "new version: $NEW_VER $NEW_HASH"
		if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		fi
	done
}
