#!/bin/sh
# AX6600 Docker 备份、恢复与升级验证辅助脚本
# 兼容 OpenWrt POSIX sh / BusyBox ash 及 Linux/Bash 环境
set -eu

SYS_ROOT="${SYS_ROOT:-}"

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# 确保命令可用，不存在则报错退出
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "缺少必要命令: $1"
        exit 1
    }
}

# 获取带 SYS_ROOT 隔离前缀的系统路径
get_sys_path() {
    p="$1"
    if [ -n "$SYS_ROOT" ]; then
        case "$p" in
            "$SYS_ROOT"*)
                echo "$p"
                ;;
            *)
                echo "${SYS_ROOT%/}/${p#/}" | sed 's|//|/|g'
                ;;
        esac
    else
        echo "$p"
    fi
}

# 解析带 SYS_ROOT 隔离前缀的真实宿主路径（隔离模式下严禁回退宿主机真实根路径）
resolve_bind_path() {
    raw_p="$1"
    if [ -n "$SYS_ROOT" ]; then
        case "$raw_p" in
            "$SYS_ROOT"*)
                echo "$raw_p"
                ;;
            *)
                echo "${SYS_ROOT%/}/${raw_p#/}" | sed 's|//|/|g'
                ;;
        esac
    else
        echo "$raw_p"
    fi
}

# POSIX shell 字符安全转义（用于生成安全的单引号命令参数）
sh_escape() {
    printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

# 挂载安全性与存储介质类型核查（支持对尚未创建的目标路径向上查找其已挂载的祖先目录，并核验设备、挂载和可用空间）
check_mount_safety() {
    target_path="$1"
    label="$2"
    min_need_kb="${3:-0}"

    [ -z "$target_path" ] && {
        log_error "$label 路径为空！"
        exit 1
    }

    check_dir="$target_path"
    while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ] && [ "$check_dir" != "." ]; do
        parent_dir=$(dirname "$check_dir")
        [ "$parent_dir" = "$check_dir" ] && break
        check_dir="$parent_dir"
    done

    if [ ! -d "$check_dir" ]; then
        log_error "$label 目录或其祖先目录不存在: $target_path"
        exit 1
    fi

    target_abs=$(cd "$check_dir" 2>/dev/null && pwd -P)
    if [ -z "$target_abs" ]; then
        log_error "无法解析 $label 目标绝对路径: $check_dir"
        exit 1
    fi

    df_out=$(df -P "$target_abs" 2>/dev/null || true)
    if [ -z "$df_out" ]; then
        log_error "无法获取 $label 挂载信息 (df 失败)"
        exit 1
    fi

    mnt_dev=$(echo "$df_out" | awk 'NR==2{print $1}')
    avail_kb=$(echo "$df_out" | awk 'NR==2{print $4}')
    mnt_point=$(echo "$df_out" | awk 'NR==2{print $6}')

    log_info "$label 挂载信息: 路径=$target_path (实际挂载根=$mnt_point), 设备=$mnt_dev, 可用=${avail_kb}KB"

    # 严禁目标位于根分区、/overlay 或只读 rom
    if [ "$mnt_point" = "/" ] || [ "$mnt_point" = "/overlay" ] || [ "$mnt_point" = "/rom" ]; then
        log_error "$label 位于根文件系统或内部 /overlay ($mnt_point, 设备: $mnt_dev)！外部业务存储未挂载，严禁在此操作！必须挂载外部独立存储介质。"
        exit 1
    fi

    # 严禁目标位于内部 overlayfs、tmpfs 或内存盘
    case "$mnt_dev" in
        *overlay*|rootfs|tmpfs|ramfs|shm)
            log_error "$label 存储设备为易失或升级重置设备 ($mnt_dev)，严禁在此操作！"
            exit 1
            ;;
    esac

    # 核验存储可用空间
    if [ "$min_need_kb" -gt 0 ]; then
        if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$min_need_kb" ]; then
            log_error "$label 存储空间不足！可用: ${avail_kb:-0}KB，所需估算: ${min_need_kb}KB"
            exit 1
        fi
    fi
}

# 剩余空间核查
check_space_safety() {
    target_path="$1"
    need_kb="$2"
    if [ -z "$target_path" ]; then
        log_error "目标存储路径为空！"
        exit 1
    fi
    target_abs=$(cd "$target_path" 2>/dev/null && pwd -P)
    if [ -z "$target_abs" ]; then
        log_error "无法解析目标存储绝对路径: $target_path"
        exit 1
    fi
    avail_kb=$(df -P "$target_abs" | awk 'NR==2{print $4}')
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
        log_error "目标存储空间不足！可用: ${avail_kb:-0}KB，所需估算: ${need_kb}KB"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 1. 升级前系统只读体检与双分区容量预检 (precheck)
# -----------------------------------------------------------------------------
do_precheck() {
    IMAGE_PATH=""
    EXPECTED_SHA=""
    SYSTEM_ONLY=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --image)
                IMAGE_PATH="$2"
                shift 2
                ;;
            --sha256)
                EXPECTED_SHA="$2"
                shift 2
                ;;
            --system-only)
                SYSTEM_ONLY=1
                shift
                ;;
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            -*)
                log_error "未知预检参数: $1"
                exit 1
                ;;
            *)
                if [ -z "$IMAGE_PATH" ]; then
                    IMAGE_PATH="$1"
                elif [ -z "$EXPECTED_SHA" ]; then
                    EXPECTED_SHA="$1"
                fi
                shift
                ;;
        esac
    done

    log_info "=== AX6600 升级前只读健康体检 ==="

    # 1. 当前固件版本与硬件型号
    RELEASE_FILE="$(get_sys_path /etc/openwrt_release)"
    MODEL_FILE="$(get_sys_path /tmp/sysinfo/model)"
    DT_MODEL="$(get_sys_path /proc/device-tree/model)"

    FW_DESC="未知"
    if [ -f "$RELEASE_FILE" ]; then
        FW_DESC=$(grep "DISTRIB_DESCRIPTION" "$RELEASE_FILE" | head -n 1 | cut -d= -f2- | tr -d '"'\''' || true)
    fi

    HW_MODEL="未知"
    if [ -f "$MODEL_FILE" ]; then
        HW_MODEL=$(cat "$MODEL_FILE" 2>/dev/null || true)
    elif [ -f "$DT_MODEL" ]; then
        HW_MODEL=$(cat "$DT_MODEL" 2>/dev/null || true)
    fi
    log_info "当前固件: ${FW_DESC:-OpenWrt} | 设备型号: ${HW_MODEL:-JDCloud AX6600 (RE-CS-02)}"

    # 2. 检查 eMMC 分区与对侧待升级目标分区 (严格遵循 OpenWrt qualcommax platform.sh 的 BOOTCONFIG 判定机制)
    MMC_DEV="/dev/mmcblk0"
    PROC_CMDLINE="$(get_sys_path /proc/cmdline)"

    BOOTCONF_DEV=""
    HLOS_SEC=0
    HLOS1_SEC=0
    ROOTFS_SEC=0
    ROOTFS1_SEC=0

    # 优先通过 sysfs (/sys/class/block 或 /sys/block/mmcblk0) 读取真实 GPT 分区 PARTNAME 与 size 扇区数
    SYS_BLOCK="$(get_sys_path /sys/class/block)"
    if [ ! -d "$SYS_BLOCK" ] && [ -d "$(get_sys_path /sys/block/mmcblk0)" ]; then
        SYS_BLOCK="$(get_sys_path /sys/block/mmcblk0)"
    fi

    if [ -d "$SYS_BLOCK" ]; then
        for pdir in "$SYS_BLOCK"/mmcblk0p*; do
            [ -d "$pdir" ] || continue
            pdev_name=$(basename "$pdir")
            uevent_file="$pdir/uevent"
            size_file="$pdir/size"
            part_name=""
            part_sec=0
            if [ -f "$uevent_file" ]; then
                part_name=$(grep -E "^PARTNAME=" "$uevent_file" | head -n 1 | cut -d= -f2- || true)
            fi
            if [ -f "$size_file" ]; then
                part_sec=$(cat "$size_file" 2>/dev/null || echo 0)
            fi
            case "$part_name" in
                "0:BOOTCONFIG")
                    BOOTCONF_DEV="/dev/$pdev_name"
                    ;;
                "0:HLOS")
                    HLOS_SEC="$part_sec"
                    ;;
                "0:HLOS_1")
                    HLOS1_SEC="$part_sec"
                    ;;
                "rootfs")
                    ROOTFS_SEC="$part_sec"
                    ;;
                "rootfs_1")
                    ROOTFS1_SEC="$part_sec"
                    ;;
            esac
        done
    fi

    # 若 sysfs 未能获取到完整系统分区信息，回退通过 fdisk -l 解析分区
    if [ "$HLOS_SEC" -eq 0 ] && [ "$ROOTFS_SEC" -eq 0 ]; then
        require_cmd fdisk
        FDISK_OUT=$(fdisk -l "$MMC_DEV" 2>/dev/null || true)
        if [ -n "$FDISK_OUT" ]; then
            [ -z "$BOOTCONF_DEV" ] && BOOTCONF_DEV=$(echo "$FDISK_OUT" | grep -E "[[:space:]]0:BOOTCONFIG([[:space:]]|$)" | awk '{print $1}' | head -n 1 || true)
            [ "$HLOS_SEC" -eq 0 ] && HLOS_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]0:HLOS([[:space:]]|$)" | awk '{print $4}' | head -n 1 || echo 0)
            [ "$HLOS1_SEC" -eq 0 ] && HLOS1_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]0:HLOS_1([[:space:]]|$)" | awk '{print $4}' | head -n 1 || echo 0)
            [ "$ROOTFS_SEC" -eq 0 ] && ROOTFS_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]rootfs([[:space:]]|$)" | awk '{print $4}' | head -n 1 || echo 0)
            [ "$ROOTFS1_SEC" -eq 0 ] && ROOTFS1_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]rootfs_1([[:space:]]|$)" | awk '{print $4}' | head -n 1 || echo 0)
        fi
    fi

    # 定位 0:BOOTCONFIG 分区设备节点 (通过 /dev/disk/by-partlabel/0:BOOTCONFIG 或 sysfs/fdisk 权威识别的设备)
    CFGPART="$(get_sys_path /dev/disk/by-partlabel/0:BOOTCONFIG)"
    if [ ! -e "$CFGPART" ] && [ -n "$BOOTCONF_DEV" ]; then
        CFGPART="$(get_sys_path "$BOOTCONF_DEV")"
    fi
    if [ ! -e "$CFGPART" ]; then
        log_error "未找到权威 0:BOOTCONFIG 分区设备节点，严禁盲猜分区设备，待升级目标不明！"
        exit 1
    fi

    PART_NUM=""
    if [ -e "$CFGPART" ]; then
        if command -v hexdump >/dev/null 2>&1; then
            PART_NUM=$(hexdump -e '1/1 "%01x|"' -n 1 -s 148 -C "$CFGPART" 2>/dev/null | cut -f 1 -d "|" | head -n1 || true)
        fi
        if [ -z "$PART_NUM" ] && command -v od >/dev/null 2>&1; then
            OD_HEX=$(od -An -tx1 -N 1 -j 148 "$CFGPART" 2>/dev/null | awk '{print $1}' || true)
            [ "$OD_HEX" = "01" ] && PART_NUM="1"
            [ "$OD_HEX" = "00" ] && PART_NUM="0"
        fi
        if [ -z "$PART_NUM" ] && command -v dd >/dev/null 2>&1; then
            RAW_BYTE=$(dd if="$CFGPART" bs=1 skip=148 count=1 2>/dev/null || true)
            if [ "$RAW_BYTE" = "$(printf '\001')" ] || [ "$RAW_BYTE" = "1" ]; then
                PART_NUM="1"
            elif [ -n "$RAW_BYTE" ]; then
                PART_NUM="0"
            fi
        fi
    fi

    if [ -z "$PART_NUM" ]; then
        log_error "无法从 0:BOOTCONFIG 分区读取启动配置标记，待升级目标分区不明，禁止盲刷！"
        exit 1
    fi

    TARGET_SRC="0:BOOTCONFIG 分区偏移 148 字节标记 ($PART_NUM)"
    TARGET_KERN=""
    TARGET_ROOTFS=""
    TARGET_KERN_SEC=0
    TARGET_ROOTFS_SEC=0

    if [ "$PART_NUM" = "1" ]; then
        TARGET_KERN="0:HLOS_1"
        TARGET_ROOTFS="rootfs_1"
        TARGET_KERN_SEC="$HLOS1_SEC"
        TARGET_ROOTFS_SEC="$ROOTFS1_SEC"
    elif [ "$PART_NUM" = "0" ]; then
        TARGET_KERN="0:HLOS"
        TARGET_ROOTFS="rootfs"
        TARGET_KERN_SEC="$HLOS_SEC"
        TARGET_ROOTFS_SEC="$ROOTFS_SEC"
    else
        log_error "0:BOOTCONFIG 偏移 148 字节标记非法 ($PART_NUM)，无法确定目标分区，禁止盲刷！"
        exit 1
    fi

    case "$TARGET_KERN_SEC" in ''|*[!0-9]*) TARGET_KERN_SEC=0 ;; esac
    case "$TARGET_ROOTFS_SEC" in ''|*[!0-9]*) TARGET_ROOTFS_SEC=0 ;; esac

    if [ "$TARGET_KERN_SEC" -le 0 ]; then
        log_error "待升级目标内核分区 [$TARGET_KERN] 未在分区表中找到有效容量记录，禁止借用其他分区容量或盲刷！"
        exit 1
    fi

    if [ "$TARGET_ROOTFS_SEC" -le 0 ]; then
        log_error "待升级目标根文件系统分区 [$TARGET_ROOTFS] 未在分区表中找到有效容量记录，禁止借用其他分区容量或盲刷！"
        exit 1
    fi

    TARGET_KERN_BYTES=$((TARGET_KERN_SEC * 512))
    TARGET_KERN_MB=$((TARGET_KERN_BYTES / 1024 / 1024))
    TARGET_ROOTFS_BYTES=$((TARGET_ROOTFS_SEC * 512))
    TARGET_ROOTFS_MB=$((TARGET_ROOTFS_BYTES / 1024 / 1024))

    log_info "待升级目标分区判定依据: $TARGET_SRC"
    log_info "  - 目标内核分区: [$TARGET_KERN] 扇区数: $TARGET_KERN_SEC (容量: ${TARGET_KERN_MB}MB)"
    log_info "  - 目标根文件系统: [$TARGET_ROOTFS] 扇区数: $TARGET_ROOTFS_SEC (容量: ${TARGET_ROOTFS_MB}MB)"

    # 3. Docker 运行状态、存储驱动、DockerRootDir 与存储介质分类
    if command -v docker >/dev/null 2>&1; then
        DK_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version 2>/dev/null || echo "未知")
        DK_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "")
        DK_DRIVER=$(docker info -f '{{.Driver}}' 2>/dev/null || echo "")
        log_info "Docker 状态: 已安装 (版本: $DK_VER, 存储驱动: $DK_DRIVER)"

        if [ -n "$DK_ROOT" ] && [ -d "$DK_ROOT" ]; then
            log_info "DockerRootDir: $DK_ROOT"
            DF_DK=$(df -P "$DK_ROOT" 2>/dev/null || true)
            DK_DEV=$(echo "$DF_DK" | awk 'NR==2{print $1}')
            DK_MNT=$(echo "$DF_DK" | awk 'NR==2{print $6}')
            case "$DK_DEV" in
                *mmcblk0p*|*overlay*|rootfs)
                    if [ "$DK_MNT" = "/" ] || [ "$DK_MNT" = "/overlay" ]; then
                        log_warn "⚠️ [高危存储分类] Docker 数据位于内部 eMMC Overlay ($DK_DEV 挂载于 $DK_MNT)！"
                        log_warn "⚠️ sysupgrade 保留配置升级时将格式化/重置内部 Flash overlay，Docker 镜像与容器数据将被清空！必须完整导出至外部介质或 PC！"
                    fi
                    ;;
                /dev/sd*|/dev/nvme*)
                    if [ "$DK_MNT" = "/overlay" ]; then
                        log_info "[存储分类] Docker 数据位于 Extroot 外置存储 ($DK_DEV 挂载于 /overlay)"
                    else
                        log_info "[存储分类] Docker 数据位于独立外部挂载介质 ($DK_DEV 挂载于 $DK_MNT, 推荐架构)"
                    fi
                    ;;
                *)
                    log_info "[存储分类] Docker 存储设备: $DK_DEV (挂载点: $DK_MNT)"
                    ;;
            esac

            VOL_CNT=$(docker volume ls -q 2>/dev/null | wc -l || echo 0)
            log_info "当前注册 Named Volumes 数量: $VOL_CNT"
        fi
    else
        log_info "Docker 状态: 未运行或命令不可用"
    fi

    # 4. 若指定固件镜像，进行镜像文件校验与容量安全核验
    if [ -n "$IMAGE_PATH" ]; then
        if [ ! -f "$IMAGE_PATH" ]; then
            log_error "固件文件不存在或匹配不唯一: $IMAGE_PATH"
            exit 1
        fi

        IMG_SIZE=$(wc -c < "$IMAGE_PATH")
        IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
        log_info "固件文件确认: $IMAGE_PATH (大小: ${IMG_SIZE_MB}MB, ${IMG_SIZE} 字节)"

        if [ -n "$EXPECTED_SHA" ]; then
            require_cmd sha256sum
            ACTUAL_SHA=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
            if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
                log_error "固件 SHA256 校验不匹配！预期: $EXPECTED_SHA，实际: $ACTUAL_SHA"
                exit 1
            fi
            log_info "固件 SHA256 校验通过: $ACTUAL_SHA"
        fi

        require_cmd sysupgrade
        log_info "执行 sysupgrade -T 格式与机型兼容性预检..."
        if ! sysupgrade -T "$IMAGE_PATH"; then
            log_error "固件与当前硬件平台不兼容，禁止刷入！"
            exit 1
        fi
        log_info "固件平台兼容性校验通过"

        # 目标内核与根文件系统容量安全阈值核验 (分别严格检查内核目标与根文件系统目标)
        ACTUAL_KERN_BYTES=0
        ACTUAL_ROOT_BYTES=0
        if tar -tf "$IMAGE_PATH" >/dev/null 2>&1; then
            TAR_ENTRIES=$(tar -tvf "$IMAGE_PATH" 2>/dev/null || true)
            ACTUAL_KERN_BYTES=$(echo "$TAR_ENTRIES" | awk '$NF ~ /(^|\/)kernel$/ {print $3}' | head -n 1 || echo 0)
            ACTUAL_ROOT_BYTES=$(echo "$TAR_ENTRIES" | awk '$NF ~ /(^|\/)root$/ {print $3}' | head -n 1 || echo 0)
            case "$ACTUAL_KERN_BYTES" in ''|*[!0-9]*) ACTUAL_KERN_BYTES=0 ;; esac
            case "$ACTUAL_ROOT_BYTES" in ''|*[!0-9]*) ACTUAL_ROOT_BYTES=0 ;; esac
        fi

        if [ "$ACTUAL_KERN_BYTES" -le 0 ]; then
            log_error "未能从固件镜像中解析到有效内核 (kernel) 大小，无法精准核验内核分区安全性！禁止盲刷！"
            exit 1
        fi
        ACTUAL_KERN_MB=$((ACTUAL_KERN_BYTES / 1024 / 1024))
        log_info "从固件 tar 镜像中提取到实际内核大小: ${ACTUAL_KERN_BYTES} 字节 (${ACTUAL_KERN_MB}MB)"
        if [ "$ACTUAL_KERN_BYTES" -gt "$TARGET_KERN_BYTES" ]; then
            log_error "待升级内核大小 (${ACTUAL_KERN_BYTES} 字节) 超过目标内核分区 [$TARGET_KERN] 容量 (${TARGET_KERN_BYTES} 字节)！禁止刷入！"
            exit 1
        fi

        if [ "$ACTUAL_ROOT_BYTES" -gt 0 ]; then
            ACTUAL_ROOT_MB=$((ACTUAL_ROOT_BYTES / 1024 / 1024))
            log_info "从固件 tar 镜像中提取到实际根文件系统大小: ${ACTUAL_ROOT_BYTES} 字节 (${ACTUAL_ROOT_MB}MB)"
            if [ "$ACTUAL_ROOT_BYTES" -gt "$TARGET_ROOTFS_BYTES" ]; then
                log_error "目标分区容量不足！待升级根文件系统大小 (${ACTUAL_ROOT_BYTES} 字节) 超过目标根文件系统分区 [$TARGET_ROOTFS] 容量 (${TARGET_ROOTFS_BYTES} 字节)！禁止刷入！"
                exit 1
            fi
            MIN_REQUIRED_BYTES=$((ACTUAL_ROOT_BYTES + 52428800))
            MIN_REQUIRED_MB=$((MIN_REQUIRED_BYTES / 1024 / 1024))
            if [ "$TARGET_ROOTFS_BYTES" -le "$MIN_REQUIRED_BYTES" ]; then
                log_error "目标分区容量 (${TARGET_ROOTFS_MB}MB) 不足！刷入 ${ACTUAL_ROOT_MB}MB 根文件系统需至少 ${MIN_REQUIRED_MB}MB 空间以保留充足 overlay！"
                exit 1
            fi
        else
            if [ "$IMG_SIZE_MB" -gt "$TARGET_ROOTFS_MB" ]; then
                log_error "目标分区容量不足！固件大小 (${IMG_SIZE_MB}MB) 超过目标根文件系统分区容量 (${TARGET_ROOTFS_MB}MB)！禁止刷入！"
                exit 1
            fi

            MIN_REQUIRED_BYTES=$((IMG_SIZE + 52428800))
            MIN_REQUIRED_MB=$((MIN_REQUIRED_BYTES / 1024 / 1024))
            if [ "$TARGET_ROOTFS_BYTES" -le "$MIN_REQUIRED_BYTES" ]; then
                log_error "目标分区容量 (${TARGET_ROOTFS_MB}MB) 不足！刷入 ${IMG_SIZE_MB}MB 固件需至少 ${MIN_REQUIRED_MB}MB 空间以保留充足 overlay！"
                exit 1
            fi
        fi

        if [ "$TARGET_ROOTFS_MB" -lt 200 ]; then
            log_error "待升级目标根文件系统分区 [$TARGET_ROOTFS] 容量仅为 ${TARGET_ROOTFS_MB}MB，小于 200MB 安全阈值！严禁在未扩容的分区刷入 PLUS 完整版固件！请选择 PURE 纯净版或通过 U-Boot 重新分区扩容。"
            exit 1
        fi

        log_info "目标分区容量安全校验通过: 根文件系统 (${TARGET_ROOTFS_MB}MB > ${MIN_REQUIRED_MB}MB), 内核 (${TARGET_KERN_MB}MB)"
    fi
}

# -----------------------------------------------------------------------------
# 2. 备份子命令 (backup)
# -----------------------------------------------------------------------------
do_backup() {
    TARGET_DIR=""
    DOCKER_ROOT_DIR=""
    COMPOSE_DIR=""
    SKIP_CONTAINER_STOP=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --target-dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            --docker-dir)
                DOCKER_ROOT_DIR="$2"
                shift 2
                ;;
            --compose-dir)
                COMPOSE_DIR="$2"
                shift 2
                ;;
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            --skip-stop)
                SKIP_CONTAINER_STOP=1
                shift
                ;;
            *)
                log_error "未知备份参数: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$TARGET_DIR" ]; then
        log_error "必须使用 --target-dir 指定备份目标目录"
        exit 1
    fi

    # 1. 探测 DockerRootDir（在 dockerd 停止前获取，绝不猜测默认目录）
    if [ -z "$DOCKER_ROOT_DIR" ]; then
        require_cmd docker
        if ! docker info >/dev/null 2>&1; then
            log_error "无法连接 Docker 守护进程，dockerd 可能未运行。请启动服务或显式通过 --docker-dir 传入。"
            exit 1
        fi
        DOCKER_ROOT_DIR=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
        if [ -z "$DOCKER_ROOT_DIR" ]; then
            log_error "获取 DockerRootDir 为空，无法确认数据存储位置！"
            exit 1
        fi
    fi

    if [ ! -d "$DOCKER_ROOT_DIR" ]; then
        log_error "DockerRootDir 目录不存在: $DOCKER_ROOT_DIR"
        exit 1
    fi
    log_info "确认 DockerRootDir: $DOCKER_ROOT_DIR"

    # 2. 检查备份目标目录挂载状态及路径合法性
    mkdir -p "$TARGET_DIR"
    check_mount_safety "$TARGET_DIR" "备份目标目录"

    TARGET_ABS=$(cd "$TARGET_DIR" && pwd -P)
    DOCKER_ABS=$(cd "$DOCKER_ROOT_DIR" && pwd -P)

    # 检查目标目录是否在 DockerRootDir 内部（防止递归无限打包）
    case "$TARGET_ABS" in
        "$DOCKER_ABS"/*|"$DOCKER_ABS")
            log_error "备份目标目录 ($TARGET_ABS) 不能在 DockerRootDir ($DOCKER_ABS) 内部！"
            exit 1
            ;;
    esac

    # 备份恢复脚本自身到目标存储，确保升级重启后 /tmp 丢失时仍可直接执行恢复
    SCRIPT_SELF="$0"
    if [ -f "$SCRIPT_SELF" ]; then
        cp "$SCRIPT_SELF" "$TARGET_ABS/docker_upgrade_helper.sh"
        chmod +x "$TARGET_ABS/docker_upgrade_helper.sh"
        log_info "已保存升级恢复辅助脚本至: $TARGET_ABS/docker_upgrade_helper.sh"
    fi

    META_DIR="$TARGET_ABS/metadata"
    mkdir -p "$META_DIR"
    COMPOSE_STORE="$TARGET_ABS/compose"
    mkdir -p "$COMPOSE_STORE"
    STANDALONE_STORE="$TARGET_ABS/standalone"
    mkdir -p "$STANDALONE_STORE"
    DB_STORE="$TARGET_ABS/databases"
    mkdir -p "$DB_STORE"

    COMPOSE_MANIFEST="$META_DIR/compose_manifest.tsv"
    : > "$COMPOSE_MANIFEST"
    STANDALONE_MANIFEST="$META_DIR/standalone_manifest.txt"
    : > "$STANDALONE_MANIFEST"
    BIND_MOUNTS_FILE="$META_DIR/bind_mounts.txt"
    : > "$BIND_MOUNTS_FILE"

    # 空间估算基准值（20MB 冗余）
    TOTAL_NEED_KB=20480

    # 3. 守护进程运行期间导出清单、网络与配置，并执行数据库应用级一致性导出
    if command -v docker >/dev/null 2>&1; then
        log_info "正在导出容器列表与元数据..."
        if ! docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META_DIR/containers_list.txt" 2>/dev/null; then
            log_error "执行 docker ps 失败，无法连接 Docker 守护进程！"
            exit 1
        fi

        C_IDS=$(docker ps -aq 2>/dev/null || true)
        RUNNING_IDS=$(docker ps -q 2>/dev/null || true)

        if [ -n "$C_IDS" ]; then
            if ! docker inspect $C_IDS > "$META_DIR/containers_inspect.json" 2>/dev/null; then
                log_error "导出容器 inspect 信息失败！"
                exit 1
            fi
        else
            echo "[]" > "$META_DIR/containers_inspect.json"
        fi

        if ! docker network ls > "$META_DIR/networks.txt" 2>/dev/null; then
            log_error "导出网络列表失败！"
            exit 1
        fi

        # 3a. 数据库应用级一致性热备 (MySQL / PostgreSQL / Redis)
        if [ -n "$RUNNING_IDS" ]; then
            for rcid in $RUNNING_IDS; do
                rcname=$(docker inspect -f '{{.Name}}' "$rcid" 2>/dev/null | tr -d '/')
                rcimg=$(docker inspect -f '{{.Config.Image}}' "$rcid" 2>/dev/null || true)

                # MySQL / MariaDB
                case "$rcname$rcimg" in
                    *mysql*|*mariadb*|*MySQL*|*MariaDB*)
                        log_info "检测到运行中的 MySQL/MariaDB 容器: $rcname ($rcimg)，正在执行一致性逻辑备份..."
                        mpass=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$rcid" 2>/dev/null | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -n 1 | cut -d= -f2- || true)
                        pwd_arg=""
                        [ -n "$mpass" ] && pwd_arg="-p$mpass"
                        dump_file="$DB_STORE/mysql_${rcname}.sql"
                        if docker exec "$rcid" mysqldump -u root $pwd_arg --all-databases --single-transaction --quick > "$dump_file" 2>/dev/null; then
                            log_info "MySQL 容器 $rcname 导出完成: $dump_file"
                            d_kb=$(du -sk "$dump_file" 2>/dev/null | awk '{print $1}' || echo 0)
                            TOTAL_NEED_KB=$((TOTAL_NEED_KB + d_kb))
                        else
                            log_warn "MySQL 容器 $rcname 自动 mysqldump 失败，容器数据将依赖 Named Volume/Bind Mount 冷备"
                            rm -f "$dump_file"
                        fi
                        ;;
                esac

                # PostgreSQL
                case "$rcname$rcimg" in
                    *postgres*|*PostgreSQL*)
                        log_info "检测到运行中的 PostgreSQL 容器: $rcname ($rcimg)，正在执行一致性逻辑备份..."
                        dump_file="$DB_STORE/postgres_${rcname}.sql"
                        if docker exec "$rcid" pg_dumpall -U postgres > "$dump_file" 2>/dev/null; then
                            log_info "PostgreSQL 容器 $rcname 导出完成: $dump_file"
                            d_kb=$(du -sk "$dump_file" 2>/dev/null | awk '{print $1}' || echo 0)
                            TOTAL_NEED_KB=$((TOTAL_NEED_KB + d_kb))
                        else
                            log_warn "PostgreSQL 容器 $rcname 自动 pg_dumpall 失败，数据将依赖冷备"
                            rm -f "$dump_file"
                        fi
                        ;;
                esac

                # Redis
                case "$rcname$rcimg" in
                    *redis*|*Redis*)
                        log_info "检测到运行中的 Redis 容器: $rcname，正在触发 SAVE 刷新持久化..."
                        docker exec "$rcid" redis-cli SAVE >/dev/null 2>&1 || docker exec "$rcid" redis-cli BGSAVE >/dev/null 2>&1 || true
                        ;;
                esac
            done
        fi

        # 3b. 处理 Compose 项目与独立容器
        if [ -n "$C_IDS" ]; then
            for cid in $C_IDS; do
                cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
                cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
                is_compose=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)
                comp_workdir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid" 2>/dev/null || true)
                comp_config=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid" 2>/dev/null || true)

                if [ -n "$is_compose" ] && [ -n "$comp_workdir" ]; then
                    actual_workdir=$(resolve_bind_path "$comp_workdir")
                    if [ ! -d "$actual_workdir" ]; then
                        if [ -n "$comp_config" ]; then
                            actual_config=$(resolve_bind_path "$comp_config")
                            if [ -f "$actual_config" ]; then
                                actual_workdir=$(dirname "$actual_config")
                            fi
                        fi
                    fi

                    if [ -d "$actual_workdir" ]; then
                        if ! grep -q "^$is_compose	" "$COMPOSE_MANIFEST" 2>/dev/null; then
                            log_info "发现 Compose 项目: $is_compose (目录: $actual_workdir)"
                            router_workdir="$comp_workdir"
                            if [ -n "$SYS_ROOT" ]; then
                                router_workdir="${actual_workdir#$SYS_ROOT}"
                                router_workdir="/${router_workdir#/}"
                            fi
                            echo "$is_compose	$router_workdir	${comp_config:-$router_workdir/docker-compose.yml}" >> "$COMPOSE_MANIFEST"
                            c_kb=$(du -sk "$actual_workdir" 2>/dev/null | awk '{print $1}' || echo 0)
                            TOTAL_NEED_KB=$((TOTAL_NEED_KB + c_kb))
                        fi
                    else
                        log_error "Compose 项目 $is_compose 的工作目录 $comp_workdir 不存在，无法完整备份！"
                        exit 1
                    fi
                else
                    log_info "发现非 Compose 独立容器: $cname (镜像: $cimg)"
                    if [ -z "$cimg" ]; then
                        log_error "非 Compose 容器 $cname 缺失镜像信息，无法重建！"
                        exit 1
                    fi
                    printf "%s\t%s\n" "$cid" "$cname" >> "$STANDALONE_MANIFEST"

                    # 检查高级/不受支持配置：遇到无法精准还原的参数在停机前明确阻断
                    net_count=$(docker inspect -f '{{len .NetworkSettings.Networks}}' "$cid" 2>/dev/null || echo 1)
                    case "$net_count" in ''|*[!0-9]*) net_count=1 ;; esac
                    if [ "$net_count" -gt 1 ]; then
                        log_error "独立容器 $cname 连接了多个网络 ($net_count 个)，单一 docker run 无法还原多网络拓扑！为防止配置丢失，已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                        exit 1
                    fi

                    cnet=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || true)
                    case "$cnet" in
                        container:*)
                            log_error "独立容器 $cname 网络模式依赖其他容器 ($cnet)，无法单独重建！为防止配置丢失，已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                            exit 1
                            ;;
                    esac

                    cipc=$(docker inspect -f '{{.HostConfig.IpcMode}}' "$cid" 2>/dev/null || true)
                    case "$cipc" in
                        container:*)
                            log_error "独立容器 $cname IPC 模式依赖其他容器 ($cipc)，无法单独重建！已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                            exit 1
                            ;;
                    esac

                    cpid=$(docker inspect -f '{{.HostConfig.PidMode}}' "$cid" 2>/dev/null || true)
                    case "$cpid" in
                        container:*)
                            log_error "独立容器 $cname PID 模式依赖其他容器 ($cpid)，无法单独重建！已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                            exit 1
                            ;;
                    esac

                    links_cnt=$(docker inspect -f '{{len .HostConfig.Links}}' "$cid" 2>/dev/null || echo 0)
                    case "$links_cnt" in ''|*[!0-9]*) links_cnt=0 ;; esac
                    if [ "$links_cnt" -gt 0 ]; then
                        log_error "独立容器 $cname 配置了 Links 容器关联，无法单命令可靠还原！为防止配置丢失，已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                        exit 1
                    fi

                    vfrom_cnt=$(docker inspect -f '{{len .HostConfig.VolumesFrom}}' "$cid" 2>/dev/null || echo 0)
                    case "$vfrom_cnt" in ''|*[!0-9]*) vfrom_cnt=0 ;; esac
                    if [ "$vfrom_cnt" -gt 0 ]; then
                        log_error "独立容器 $cname 依赖了其他容器的数据卷 (--volumes-from)，无法单命令还原依赖顺序！为防止配置丢失，已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                        exit 1
                    fi

                    cruntime=$(docker inspect -f '{{.HostConfig.Runtime}}' "$cid" 2>/dev/null || true)
                    if [ -n "$cruntime" ] && [ "$cruntime" != "runc" ] && [ "$cruntime" != "default" ]; then
                        log_error "独立容器 $cname 使用了自定义运行时 ($cruntime)，当前系统无法保证还原！已在备份阶段阻断。"
                        exit 1
                    fi

                    # 检查 HostConfig.Mounts（--mount）配置
                    if ! cmounts_raw=$(docker inspect -f '{{range .HostConfig.Mounts}}{{.Type}}|{{.Source}}|{{.Target}}|{{.ReadOnly}}
{{end}}' "$cid" 2>/dev/null); then
                        log_error "读取独立容器 $cname 的 Mount 配置失败！已在修改服务状态前阻断。"
                        exit 1
                    fi
                    if [ -n "$cmounts_raw" ]; then
                        echo "$cmounts_raw" | while IFS= read -r mline || [ -n "$mline" ]; do
                            [ -z "$mline" ] && continue
                            m_type=$(echo "$mline" | cut -d'|' -f1)
                            m_src=$(echo "$mline" | cut -d'|' -f2)
                            case "$m_type" in
                                bind)
                                    if [ -n "$m_src" ]; then
                                        actual_msrc=$(resolve_bind_path "$m_src")
                                        if [ ! -e "$actual_msrc" ]; then
                                            log_error "独立容器 $cname 的 --mount bind 宿主机路径不存在: $m_src ，无法保证备份完整！已在修改服务状态前阻断。"
                                            exit 1
                                        fi
                                    fi
                                    ;;
                                volume|tmpfs)
                                    ;;
                                *)
                                    log_error "独立容器 $cname 使用了不受支持的 Mount 类型 ($m_type)！已在备份阶段阻断。请将其迁移为 Docker Compose 编排管理。"
                                    exit 1
                                    ;;
                            esac
                        done
                    fi

                    # 估算容器基础镜像所需空间
                    TOTAL_NEED_KB=$((TOTAL_NEED_KB + 51200))
                fi
            done
        fi

        # 处理显式指定的 Compose 目录（仅登记元数据，冷备归档延后至停机后）
        if [ -n "$COMPOSE_DIR" ] && [ -d "$COMPOSE_DIR" ]; then
            comp_abs=$(cd "$COMPOSE_DIR" && pwd -P)
            pname=$(basename "$comp_abs")
            if ! grep -q "^$pname	" "$COMPOSE_MANIFEST" 2>/dev/null; then
                log_info "登记显式指定的 Compose 目录: $comp_abs"
                echo "$pname	$comp_abs	$comp_abs/docker-compose.yml" >> "$COMPOSE_MANIFEST"
                c_kb=$(du -sk "$comp_abs" 2>/dev/null | awk '{print $1}' || echo 0)
                TOTAL_NEED_KB=$((TOTAL_NEED_KB + c_kb))
            fi
        fi

        # 扫描外部 Bind Mounts (使用 Docker 模板只导出真正 Type=bind 的挂载路径，严禁使用 grep 抓取整段 JSON 误判命名卷)
        : > "$META_DIR/bind_mounts_raw.txt"
        if [ -n "$C_IDS" ]; then
            for cid in $C_IDS; do
                if ! docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{println}}{{end}}{{end}}' "$cid" >> "$META_DIR/bind_mounts_raw.txt" 2>/dev/null; then
                    log_error "读取容器 $cid 挂载清单失败，无法保证备份完整！已在修改服务状态前阻断。"
                    exit 1
                fi
            done
        fi
        sort -u "$META_DIR/bind_mounts_raw.txt" -o "$META_DIR/bind_mounts_raw.txt" || true
        while IFS= read -r mpath; do
            mpath=$(echo "$mpath" | tr -d '\r')
            [ -z "$mpath" ] && continue
            case "$mpath" in
                /proc*|/sys*|/dev*|/etc/resolv.conf|/etc/hosts|/etc/hostname|"$DOCKER_ABS"*)
                    continue
                    ;;
                *)
                    actual_path=$(resolve_bind_path "$mpath")
                    if [ -e "$actual_path" ]; then
                        echo "$mpath" >> "$BIND_MOUNTS_FILE"
                        b_kb=$(du -sk "$actual_path" 2>/dev/null | awk '{print $1}' || echo 0)
                        TOTAL_NEED_KB=$((TOTAL_NEED_KB + b_kb))
                    else
                        log_error "容器引用的外部挂载路径不存在: $mpath ，无法保证备份完整！"
                        exit 1
                    fi
                    ;;
            esac
        done < "$META_DIR/bind_mounts_raw.txt"
    fi

    # 计算 Named Volumes 容量
    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        v_kb=$(du -sk "$DOCKER_ROOT_DIR/volumes" 2>/dev/null | awk '{print $1}' || echo 0)
        TOTAL_NEED_KB=$((TOTAL_NEED_KB + v_kb))
    fi

    # 完整覆盖全部待备份数据的空间检查（修改任何服务状态前先核验目标存储）
    check_space_safety "$TARGET_ABS" "$TOTAL_NEED_KB"

    # 4. 记录原开机自启状态并在升级前安全禁用
    AUTOSTART_FILE="$TARGET_ABS/docker_autostart.state"
    INIT_DOCKERD="$(get_sys_path /etc/init.d/dockerd)"
    WAS_ENABLED="0"
    if [ -x "$INIT_DOCKERD" ]; then
        if "$INIT_DOCKERD" enabled 2>/dev/null; then
            WAS_ENABLED="1"
            echo "1" > "$AUTOSTART_FILE"
            log_info "已记录 Docker 为开机自启状态，升级前临时禁用自启以防在空目录误启动..."
            "$INIT_DOCKERD" disable || {
                log_error "无法禁用 dockerd 开机自启！"
                exit 1
            }
            if "$INIT_DOCKERD" enabled 2>/dev/null; then
                log_error "dockerd 自启禁用验证失败！"
                exit 1
            fi
        else
            echo "0" > "$AUTOSTART_FILE"
            log_info "Docker 原本非开机自启"
        fi
    else
        echo "0" > "$AUTOSTART_FILE"
    fi

    # 5. 严格停机与快照执行顺序：
    # 导出元数据和热备 → 停容器 → commit/save 快照 → 停 dockerd → 归档持久化数据
    if [ "$SKIP_CONTAINER_STOP" -eq 0 ]; then
        if command -v docker >/dev/null 2>&1; then
            RUNNING=$(docker ps -q 2>/dev/null || true)
            if [ -n "$RUNNING" ]; then
                log_info "正在停止运行中的 Docker 容器以保证数据落盘与冷备一致性..."
                if ! docker stop $RUNNING >/dev/null; then
                    log_error "停止容器失败！无法保证冷备数据一致性。若需恢复原服务状态，请执行: $INIT_DOCKERD start"
                    [ "$WAS_ENABLED" = "1" ] && [ -x "$INIT_DOCKERD" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                    exit 1
                fi
            fi
        fi
    fi

    # 5b. 容器停机后执行 commit/save 保存快照（此时容器已完成关机落盘，可写层为最新一致性数据）
    if [ -f "$STANDALONE_MANIFEST" ] && command -v docker >/dev/null 2>&1; then
        while IFS='	' read -r scid scname || [ -n "$scid" ]; do
            [ -z "$scid" ] && continue
            if [ -n "$scname" ]; then
                cid="$scid"
                cname="$scname"
            else
                cname="$scid"
                cid=$(docker inspect -f '{{.Id}}' "$cname" 2>/dev/null || echo "")
                [ -z "$cid" ] && cid="$cname"
            fi
            cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)

            has_diff=0
            diff_out=$(docker diff "$cid" 2>/dev/null || true)
            filtered_diff=$(echo "$diff_out" | grep -vE "^[ACD] (/tmp|/run|/var/log|/var/run|/dev)" || true)
            img_for_run="$cimg"
            if [ -n "$filtered_diff" ]; then
                has_diff=1
                log_info "容器 $cname 停机后可写层存在变动，执行 commit 保存增量镜像快照..."
                snap_tag="backup-snapshot-$cname:latest"
                docker commit "$cid" "$snap_tag" || {
                    log_error "容器 $cname commit 快照失败！"
                    exit 1
                }
                docker save "$snap_tag" -o "$STANDALONE_STORE/image_${cname}.tar" || {
                    log_error "导出容器 $cname 快照镜像失败！"
                    exit 1
                }
                img_for_run="$snap_tag"
            else
                log_info "容器 $cname 可写层无变动，导出基础镜像: $cimg ..."
                docker save "$cimg" -o "$STANDALONE_STORE/image_${cname}.tar" || {
                    log_error "导出容器 $cname 基础镜像 $cimg 失败！"
                    exit 1
                }
            fi

            # 生成独立容器重建脚本（完整还原支持的设置：-e, -p, -v, --mount, --net, --restart, --privileged, -u, -w, -h, --entrypoint, --device, --cap-add, --cap-drop, --dns, Cmd）
            rec_script="$STANDALONE_STORE/recreate_${cname}.sh"
            crestart_name=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || true)
            crestart_max=$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$cid" 2>/dev/null || true)
            case "$crestart_max" in ''|*[!0-9]*) crestart_max=0 ;; esac
            crestart="$crestart_name"
            if [ "$crestart_name" = "on-failure" ] && [ -n "$crestart_max" ] && [ "$crestart_max" -gt 0 ]; then
                crestart="on-failure:$crestart_max"
            fi

            cnet=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || true)
            cpriv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid" 2>/dev/null || true)
            cuser=$(docker inspect -f '{{.Config.User}}' "$cid" 2>/dev/null || true)
            cworkdir=$(docker inspect -f '{{.Config.WorkingDir}}' "$cid" 2>/dev/null || true)
            chostname=$(docker inspect -f '{{.Config.Hostname}}' "$cid" 2>/dev/null || true)

            # 完整解析 Entrypoint 参数（支持多参数 /bin/sh -c 等）
            centrypoints=$(docker inspect -f '{{range .Config.Entrypoint}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)
            ep_bin=""
            ep_extra=""
            if [ -n "$centrypoints" ]; then
                ep_bin=$(echo "$centrypoints" | head -n 1)
                ep_extra=$(echo "$centrypoints" | sed '1d')
            fi

            cports=$(docker inspect -f '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}}
{{end}}{{end}}' "$cid" 2>/dev/null || true)

            cenvs=$(docker inspect -f '{{range .Config.Env}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            cbinds=$(docker inspect -f '{{range .HostConfig.Binds}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            cmounts=$(docker inspect -f '{{range .HostConfig.Mounts}}{{.Type}}|{{.Source}}|{{.Target}}|{{.ReadOnly}}
{{end}}' "$cid" 2>/dev/null || true)

            cdevices=$(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}}:{{.PathInContainer}}:{{.CgroupPermissions}}
{{end}}' "$cid" 2>/dev/null || true)

            ccaps_add=$(docker inspect -f '{{range .HostConfig.CapAdd}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            ccaps_drop=$(docker inspect -f '{{range .HostConfig.CapDrop}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            cdns=$(docker inspect -f '{{range .HostConfig.Dns}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            ccmd=$(docker inspect -f '{{range .Config.Cmd}}{{.}}
{{end}}' "$cid" 2>/dev/null || true)

            cat << EOF_REC > "$rec_script"
#!/bin/sh
set -e
STANDALONE_DIR="\${STANDALONE_DIR:-\$(cd "\$(dirname "\$0")" && pwd -P)}"
echo "正在重建独立容器: $cname..."
docker rm -f "$cname" 2>/dev/null || true
if [ -f "\$STANDALONE_DIR/image_${cname}.tar" ]; then
    docker load -i "\$STANDALONE_DIR/image_${cname}.tar"
fi
EOF_REC

            printf "docker run -d --name '%s'" "$(sh_escape "$cname")" >> "$rec_script"
            [ -n "$cnet" ] && [ "$cnet" != "default" ] && printf " --net '%s'" "$(sh_escape "$cnet")" >> "$rec_script"
            [ -n "$crestart" ] && [ "$crestart" != "no" ] && printf " --restart '%s'" "$(sh_escape "$crestart")" >> "$rec_script"
            [ "$cpriv" = "true" ] && printf " --privileged" >> "$rec_script"
            [ -n "$cuser" ] && printf " -u '%s'" "$(sh_escape "$cuser")" >> "$rec_script"
            [ -n "$cworkdir" ] && printf " -w '%s'" "$(sh_escape "$cworkdir")" >> "$rec_script"
            [ -n "$chostname" ] && printf " -h '%s'" "$(sh_escape "$chostname")" >> "$rec_script"
            [ -n "$ep_bin" ] && printf " --entrypoint '%s'" "$(sh_escape "$ep_bin")" >> "$rec_script"

            if [ -n "$cports" ]; then
                echo "$cports" | while IFS= read -r p_item || [ -n "$p_item" ]; do
                    [ -z "$p_item" ] && continue
                    printf " -p '%s'" "$(sh_escape "$p_item")" >> "$rec_script"
                done
            fi

            if [ -n "$cenvs" ]; then
                echo "$cenvs" | while IFS= read -r e_item || [ -n "$e_item" ]; do
                    [ -z "$e_item" ] && continue
                    printf " -e '%s'" "$(sh_escape "$e_item")" >> "$rec_script"
                done
            fi

            if [ -n "$cbinds" ]; then
                echo "$cbinds" | while IFS= read -r b_item || [ -n "$b_item" ]; do
                    [ -z "$b_item" ] && continue
                    printf " -v '%s'" "$(sh_escape "$b_item")" >> "$rec_script"
                done
            fi

            if [ -n "$cmounts" ]; then
                echo "$cmounts" | while IFS= read -r mline || [ -n "$mline" ]; do
                    [ -z "$mline" ] && continue
                    m_type=$(echo "$mline" | cut -d'|' -f1)
                    m_src=$(echo "$mline" | cut -d'|' -f2)
                    m_dst=$(echo "$mline" | cut -d'|' -f3)
                    m_ro=$(echo "$mline" | cut -d'|' -f4)
                    case "$m_type" in
                        bind)
                            m_opt="type=bind,source=$m_src,target=$m_dst"
                            [ "$m_ro" = "true" ] && m_opt="${m_opt},readonly"
                            printf " --mount '%s'" "$(sh_escape "$m_opt")" >> "$rec_script"
                            ;;
                        volume)
                            m_opt="type=volume,source=$m_src,target=$m_dst"
                            [ "$m_ro" = "true" ] && m_opt="${m_opt},readonly"
                            printf " --mount '%s'" "$(sh_escape "$m_opt")" >> "$rec_script"
                            ;;
                        tmpfs)
                            m_opt="type=tmpfs,target=$m_dst"
                            printf " --mount '%s'" "$(sh_escape "$m_opt")" >> "$rec_script"
                            ;;
                    esac
                done
            fi

            if [ -n "$cdevices" ]; then
                echo "$cdevices" | while IFS= read -r d_item || [ -n "$d_item" ]; do
                    [ -z "$d_item" ] && continue
                    printf " --device '%s'" "$(sh_escape "$d_item")" >> "$rec_script"
                done
            fi

            if [ -n "$ccaps_add" ]; then
                echo "$ccaps_add" | while IFS= read -r ca_item || [ -n "$ca_item" ]; do
                    [ -z "$ca_item" ] && continue
                    printf " --cap-add '%s'" "$(sh_escape "$ca_item")" >> "$rec_script"
                done
            fi

            if [ -n "$ccaps_drop" ]; then
                echo "$ccaps_drop" | while IFS= read -r cd_item || [ -n "$cd_item" ]; do
                    [ -z "$cd_item" ] && continue
                    printf " --cap-drop '%s'" "$(sh_escape "$cd_item")" >> "$rec_script"
                done
            fi

            if [ -n "$cdns" ]; then
                echo "$cdns" | while IFS= read -r dns_item || [ -n "$dns_item" ]; do
                    [ -z "$dns_item" ] && continue
                    printf " --dns '%s'" "$(sh_escape "$dns_item")" >> "$rec_script"
                done
            fi

            printf " '%s'" "$(sh_escape "$img_for_run")" >> "$rec_script"

            if [ -n "$ep_extra" ]; then
                echo "$ep_extra" | while IFS= read -r ep_arg || [ -n "$ep_arg" ]; do
                    [ -z "$ep_arg" ] && continue
                    printf " '%s'" "$(sh_escape "$ep_arg")" >> "$rec_script"
                done
            fi

            if [ -n "$ccmd" ]; then
                echo "$ccmd" | while IFS= read -r a_item || [ -n "$a_item" ]; do
                    [ -z "$a_item" ] && continue
                    printf " '%s'" "$(sh_escape "$a_item")" >> "$rec_script"
                done
            fi

            printf "\n" >> "$rec_script"
            chmod +x "$rec_script"
        done < "$STANDALONE_MANIFEST"
    fi

    # 5c. 停止 dockerd 守护进程
    if [ "$SKIP_CONTAINER_STOP" -eq 0 ]; then
        if [ -x "$INIT_DOCKERD" ]; then
            log_info "停止 dockerd 守护进程..."
            if ! "$INIT_DOCKERD" stop >/dev/null; then
                log_error "停止 dockerd 服务失败！"
                [ "$WAS_ENABLED" = "1" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                exit 1
            fi
            if pgrep -x dockerd >/dev/null 2>&1; then
                log_error "dockerd 进程未能成功停止！"
                [ "$WAS_ENABLED" = "1" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                exit 1
            fi
        fi
    fi

    # 6. 统一格式备份配置
    CONFIG_DIR="$TARGET_ABS/config"
    mkdir -p "$CONFIG_DIR"
    ETC_DIR="$(get_sys_path /etc)"
    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"

    if [ -d "$ETC_DIR/docker" ]; then
        mkdir -p "$CONFIG_DIR/etc_docker"
        cp -r "$ETC_DIR/docker/." "$CONFIG_DIR/etc_docker/" || {
            log_error "备份 $ETC_DIR/docker 失败！"
            exit 1
        }
    fi
    if [ -f "$CONFIG_DIR_HOST/dockerd" ]; then
        cp "$CONFIG_DIR_HOST/dockerd" "$CONFIG_DIR/config_dockerd" || {
            log_error "备份 $CONFIG_DIR_HOST/dockerd 失败！"
            exit 1
        }
    fi
    if [ -f "$CONFIG_DIR_HOST/dockerman" ]; then
        cp "$CONFIG_DIR_HOST/dockerman" "$CONFIG_DIR/config_dockerman" || {
            log_error "备份 $CONFIG_DIR_HOST/dockerman 失败！"
            exit 1
        }
    fi

    # 7. 归档 Named Volumes 并校验完整性
    require_cmd tar
    VOL_ARCHIVE="$TARGET_ABS/docker_volumes.tar.gz"
    UNCOMP_FILE="$META_DIR/uncompressed_sizes.tsv"
    : > "$UNCOMP_FILE"

    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        log_info "正在归档 Named Volumes..."
        vol_uncomp_kb=$(du -sk "$DOCKER_ROOT_DIR/volumes" 2>/dev/null | awk '{print $1}' || echo 0)
        echo "volumes	docker_volumes.tar.gz	$vol_uncomp_kb" >> "$UNCOMP_FILE"
        tar -czf "$VOL_ARCHIVE" -C "$DOCKER_ROOT_DIR" volumes || {
            log_error "Named Volumes 归档打包失败！"
            exit 1
        }
        tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1 || {
            log_error "Named Volumes 归档验证失败，文件损坏！"
            exit 1
        }
        TAR_VOL_LIST=$(tar -tzf "$VOL_ARCHIVE")
        for vitem in "$DOCKER_ROOT_DIR/volumes"/*; do
            [ -e "$vitem" ] || continue
            vbase=$(basename "$vitem")
            if ! echo "$TAR_VOL_LIST" | grep -q "volumes/$vbase"; then
                log_error "Named Volumes 归档遗漏了 volume: $vbase！"
                exit 1
            fi
        done
    else
        echo "volumes	docker_volumes.tar.gz	0" >> "$UNCOMP_FILE"
        mkdir -p "$TARGET_ABS/.empty_vol/volumes"
        tar -czf "$VOL_ARCHIVE" -C "$TARGET_ABS/.empty_vol" volumes
        rm -rf "$TARGET_ABS/.empty_vol"
        tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1 || {
            log_error "创建空 Volumes 归档失败！"
            exit 1
        }
    fi

    # 8. 停机后归档 Compose 项目目录（冷备一致性保证，在停机后归档，确保与 Bind Mounts 状态同步）
    if [ -f "$COMPOSE_MANIFEST" ]; then
        log_info "正在冷备归档 Compose 项目目录..."
        while IFS='	' read -r cproj cdir ccfg || [ -n "$cproj" ]; do
            [ -z "$cproj" ] && continue
            actual_cdir=$(resolve_bind_path "$cdir")
            if [ -d "$actual_cdir" ]; then
                proj_archive="$COMPOSE_STORE/${cproj}.tar.gz"
                proj_uncomp_kb=$(du -sk "$actual_cdir" 2>/dev/null | awk '{print $1}' || echo 0)
                echo "compose	$cproj	${cproj}.tar.gz	$proj_uncomp_kb" >> "$UNCOMP_FILE"
                tar -czf "$proj_archive" -C "$actual_cdir" . || {
                    log_error "归档 Compose 项目 $cproj 失败！"
                    exit 1
                }
                tar -tzf "$proj_archive" >/dev/null 2>&1 || {
                    log_error "Compose 归档 $proj_archive 校验损坏！"
                    exit 1
                }
            else
                log_error "Compose 项目 $cproj 目录不存在: $actual_cdir"
                exit 1
            fi
        done < "$COMPOSE_MANIFEST"
    fi

    # 9. 归档 Bind Mounts 并校验完整性
    BIND_ARCHIVE="$TARGET_ABS/docker_bind_mounts.tar.gz"
    if [ -s "$BIND_MOUNTS_FILE" ]; then
        log_info "正在归档外部 Bind Mounts 数据..."
        TAR_FILE_LIST="$META_DIR/tar_bind_list.txt"
        : > "$TAR_FILE_LIST"
        while IFS= read -r mpath; do
            [ -z "$mpath" ] && continue
            actual_p=$(resolve_bind_path "$mpath")
            b_uncomp_kb=$(du -sk "$actual_p" 2>/dev/null | awk '{print $1}' || echo 0)
            echo "bind	$mpath	docker_bind_mounts.tar.gz	$b_uncomp_kb" >> "$UNCOMP_FILE"
            if [ -n "$SYS_ROOT" ]; then
                rel_p="${actual_p#$SYS_ROOT}"
                rel_p="${rel_p#/}"
                echo "$rel_p" >> "$TAR_FILE_LIST"
            else
                echo "${mpath#/}" >> "$TAR_FILE_LIST"
            fi
        done < "$BIND_MOUNTS_FILE"

        if [ -n "$SYS_ROOT" ]; then
            tar -czf "$BIND_ARCHIVE" -C "$SYS_ROOT" -T "$TAR_FILE_LIST" || {
                log_error "Bind Mounts 归档打包失败！"
                exit 1
            }
        else
            tar -czf "$BIND_ARCHIVE" -C / -T "$TAR_FILE_LIST" || {
                log_error "Bind Mounts 归档打包失败！"
                exit 1
            }
        fi

        tar -tzf "$BIND_ARCHIVE" >/dev/null 2>&1 || {
            log_error "Bind Mounts 归档验证失败，文件损坏！"
            exit 1
        }
        TAR_BIND_LIST=$(tar -tzf "$BIND_ARCHIVE")
        while IFS= read -r mpath; do
            [ -z "$mpath" ] && continue
            actual_p=$(resolve_bind_path "$mpath")
            if [ -n "$SYS_ROOT" ]; then
                rel_p="${actual_p#$SYS_ROOT}"
                rel_p="${rel_p#/}"
            else
                rel_p="${mpath#/}"
            fi
            if ! echo "$TAR_BIND_LIST" | grep -q "$rel_p"; then
                log_error "Bind Mounts 归档遗漏文件或目录: $mpath ！"
                exit 1
            fi
        done < "$BIND_MOUNTS_FILE"
    fi

    # 10. 生成全局备份校验清单与 SHA256 校验和（覆盖所有归档、脚本、配置与数据库，严格排除清单自身并立即自检）
    log_info "生成全局备份校验清单与 SHA256 校验和..."
    require_cmd sha256sum
    (
        cd "$TARGET_ABS"
        rm -f sha256sums.txt backup_manifest.txt .sha256sums.tmp
        # 遍历目标目录下所有常规文件，严格排除校验清单自身、backup_manifest.txt 与任何以点开头的临时文件
        find . -type f ! -name "sha256sums.txt" ! -name "backup_manifest.txt" ! -name ".*" | sort | while IFS= read -r f; do
            clean_f="${f#./}"
            sha256sum "$clean_f"
        done > .sha256sums.tmp

        {
            echo "AX6600 Docker 备份摘要清单"
            echo "生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)"
            echo "DockerRootDir: $DOCKER_ROOT_DIR"
            echo "开机自启记录: $(cat docker_autostart.state 2>/dev/null || echo '0')"
            echo "Named Volumes 归档: docker_volumes.tar.gz"
            [ -f "docker_bind_mounts.tar.gz" ] && echo "Bind Mounts 归档: docker_bind_mounts.tar.gz"
            echo "Compose 项目数: $(wc -l < metadata/compose_manifest.tsv 2>/dev/null || echo 0)"
            echo "独立容器数: $(wc -l < metadata/standalone_manifest.txt 2>/dev/null || echo 0)"
            echo "备份文件总数: $(( $(wc -l < .sha256sums.tmp) + 1 ))"
            echo ""
            echo "[UNCOMPRESSED_SIZES_KB]"
            cat metadata/uncompressed_sizes.tsv 2>/dev/null || true
            echo ""
            echo "[FILES]"
            sed 's/^[0-9a-fA-F]* [ *]*//' .sha256sums.tmp
            echo "backup_manifest.txt"
        } > backup_manifest.txt
        sha256sum backup_manifest.txt >> .sha256sums.tmp
        mv .sha256sums.tmp sha256sums.txt

        log_info "正在对生成的备份文件与校验清单执行即时自检核验..."
        if ! sha256sum -c sha256sums.txt >/dev/null 2>&1; then
            log_error "备份文件自检核验失败！"
            exit 1
        fi
        log_info "备份文件自检核验通过"
    )

    log_info "Docker 完整备份完成，校验清单与全部文件哈希位于: $TARGET_ABS/sha256sums.txt"
}

# -----------------------------------------------------------------------------
# 3. 恢复子命令 (restore)
# -----------------------------------------------------------------------------
do_restore() {
    BACKUP_DIR=""
    TARGET_DATA_ROOT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --target-data-root)
                TARGET_DATA_ROOT="$2"
                shift 2
                ;;
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            *)
                log_error "未知恢复参数: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$BACKUP_DIR" ] || [ -z "$TARGET_DATA_ROOT" ]; then
        log_error "恢复必须同时指定 --backup-dir 和 --target-data-root"
        exit 1
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "备份目录不存在: $BACKUP_DIR"
        exit 1
    fi

    # 1. 严格校验全部备份构件完整性与哈希清单
    require_cmd sha256sum
    require_cmd tar
    if [ ! -f "$BACKUP_DIR/sha256sums.txt" ] || [ ! -f "$BACKUP_DIR/docker_volumes.tar.gz" ] || [ ! -f "$BACKUP_DIR/backup_manifest.txt" ]; then
        log_error "备份文件不完整（缺少 sha256sums.txt、backup_manifest.txt 或 docker_volumes.tar.gz）！"
        exit 1
    fi

    log_info "正在核对全部备份文件 SHA256 校验和..."
    (
        cd "$BACKUP_DIR"
        sha256sum -c sha256sums.txt
    ) || {
        log_error "备份文件完整性校验失败，数据存在缺失、篡改或损坏！严禁继续恢复！"
        exit 1
    }

    # 交叉核查所有清单组件实体是否存在且未损坏
    COMPOSE_MANIFEST="$BACKUP_DIR/metadata/compose_manifest.tsv"
    if [ -f "$COMPOSE_MANIFEST" ]; then
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            proj_tar="$BACKUP_DIR/compose/${proj_name}.tar.gz"
            if [ ! -f "$proj_tar" ]; then
                log_error "关键备份文件缺失: Compose 归档 $proj_tar 不存在！禁止恢复！"
                exit 1
            fi
            if ! tar -tzf "$proj_tar" >/dev/null 2>&1; then
                log_error "Compose 归档 $proj_tar 文件损坏！禁止恢复！"
                exit 1
            fi
        done < "$COMPOSE_MANIFEST"
    fi

    STANDALONE_MANIFEST="$BACKUP_DIR/metadata/standalone_manifest.txt"
    if [ -f "$STANDALONE_MANIFEST" ]; then
        while IFS='	' read -r scid scname || [ -n "$scid" ]; do
            [ -z "$scid" ] && continue
            if [ -n "$scname" ]; then
                cname="$scname"
            else
                cname="$scid"
            fi
            rec_sh="$BACKUP_DIR/standalone/recreate_${cname}.sh"
            img_tar="$BACKUP_DIR/standalone/image_${cname}.tar"
            if [ ! -f "$rec_sh" ]; then
                log_error "关键备份文件缺失: 独立容器重建脚本 $rec_sh 不存在！禁止恢复！"
                exit 1
            fi
            if [ ! -f "$img_tar" ]; then
                log_error "关键备份文件缺失: 独立容器镜像归档 $img_tar 不存在！禁止恢复！"
                exit 1
            fi
            if ! tar -tf "$img_tar" >/dev/null 2>&1; then
                log_error "独立容器镜像归档 $img_tar 文件损坏！禁止恢复！"
                exit 1
            fi
        done < "$STANDALONE_MANIFEST"
    fi

    BIND_MANIFEST="$BACKUP_DIR/metadata/bind_mounts.txt"
    if [ -s "$BIND_MANIFEST" ]; then
        if [ ! -f "$BACKUP_DIR/docker_bind_mounts.tar.gz" ]; then
            log_error "关键备份文件缺失: 存在 Bind Mounts 记录但缺少归档 docker_bind_mounts.tar.gz！禁止恢复！"
            exit 1
        fi
        if ! tar -tzf "$BACKUP_DIR/docker_bind_mounts.tar.gz" >/dev/null 2>&1; then
            log_error "Bind Mounts 归档 docker_bind_mounts.tar.gz 损坏！禁止恢复！"
            exit 1
        fi
    fi

    # 遍历 backup_manifest.txt 中记录的所有文件，确保无一遗漏
    in_files=0
    while IFS= read -r mline || [ -n "$mline" ]; do
        if [ "$mline" = "[FILES]" ]; then
            in_files=1
            continue
        fi
        [ "$in_files" -eq 1 ] || continue
        [ -z "$mline" ] && continue
        if [ ! -f "$BACKUP_DIR/$mline" ]; then
            log_error "关键备份文件缺失: 清单记录的文件 $mline 不存在！禁止恢复！"
            exit 1
        fi
    done < "$BACKUP_DIR/backup_manifest.txt"

    # 2. 确认恢复端所有目标路径真实挂载在外部存储，记录各组件解压所需真实空间并按目标文件系统汇总核验
    log_info "正在预检全部恢复目标的挂载设备、安全与汇总可用空间..."
    if [ -z "$TARGET_DATA_ROOT" ]; then
        log_error "目标 DataRoot 存储路径为空！"
        exit 1
    fi
    mkdir -p "$TARGET_DATA_ROOT"
    TARGET_DATA_ABS=$(cd "$TARGET_DATA_ROOT" 2>/dev/null && pwd -P)
    if [ -z "$TARGET_DATA_ABS" ]; then
        log_error "无法解析目标 DataRoot 绝对路径: $TARGET_DATA_ROOT"
        exit 1
    fi

    UNCOMP_FILE="$BACKUP_DIR/metadata/uncompressed_sizes.tsv"

    get_uncompressed_kb() {
        comp_type="$1"
        key_name="$2"
        archive_path="$3"

        val=0
        if [ -f "$UNCOMP_FILE" ]; then
            bare_key="${key_name%.tar.gz}"
            val=$(grep -E "^$comp_type	($key_name|$bare_key|${bare_key}.tar.gz)	" "$UNCOMP_FILE" 2>/dev/null | head -n 1 | awk '{print $NF}' || echo 0)
            case "$val" in ''|*[!0-9]*) val=0 ;; esac
        fi
        if [ "$val" -le 0 ] && [ -f "$archive_path" ]; then
            val=$(tar -tvf "$archive_path" 2>/dev/null | awk '{sum += $3} END {print int(sum/1024)}' || echo 0)
            case "$val" in ''|*[!0-9]*) val=0 ;; esac
        fi
        echo "$val"
    }

    RESTORE_MNT_REQS="$BACKUP_DIR/metadata/restore_mnt_reqs.tmp"
    : > "$RESTORE_MNT_REQS"

    # 登记目标 DataRoot 需求
    vol_uncomp_kb=$(get_uncompressed_kb "volumes" "docker_volumes.tar.gz" "$BACKUP_DIR/docker_volumes.tar.gz")
    check_mount_safety "$TARGET_DATA_ROOT" "目标 DataRoot 目录" 0
    df_vol=$(df -P "$TARGET_DATA_ABS" 2>/dev/null || true)
    m_pt=$(echo "$df_vol" | awk 'NR==2{print $6}')
    m_dev=$(echo "$df_vol" | awk 'NR==2{print $1}')
    m_avail=$(echo "$df_vol" | awk 'NR==2{print $4}')
    echo "$m_pt	$m_dev	$m_avail	$vol_uncomp_kb" >> "$RESTORE_MNT_REQS"

    # 登记各 Compose 项目需求
    if [ -f "$COMPOSE_MANIFEST" ]; then
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            dest_dir=$(resolve_bind_path "$orig_dir")
            check_mount_safety "$dest_dir" "Compose 项目 [$proj_name] 目标目录 ($orig_dir)" 0
            proj_tar="$BACKUP_DIR/compose/${proj_name}.tar.gz"
            proj_uncomp_kb=$(get_uncompressed_kb "compose" "$proj_name" "$proj_tar")
            if [ -d "$dest_dir" ]; then
                dest_abs=$(cd "$dest_dir" && pwd -P)
            else
                mkdir -p "$dest_dir"
                dest_abs=$(cd "$dest_dir" && pwd -P)
            fi
            if [ -z "$dest_abs" ]; then
                log_error "无法解析 Compose 项目 [$proj_name] 目标绝对路径: $dest_dir"
                exit 1
            fi
            df_proj=$(df -P "$dest_abs" 2>/dev/null || true)
            p_pt=$(echo "$df_proj" | awk 'NR==2{print $6}')
            p_dev=$(echo "$df_proj" | awk 'NR==2{print $1}')
            p_avail=$(echo "$df_proj" | awk 'NR==2{print $4}')
            echo "$p_pt	$p_dev	$p_avail	$proj_uncomp_kb" >> "$RESTORE_MNT_REQS"
        done < "$COMPOSE_MANIFEST"
    fi

    # 登记各 Bind Mounts 需求
    if [ -f "$BIND_MANIFEST" ]; then
        while IFS= read -r mpath || [ -n "$mpath" ]; do
            [ -z "$mpath" ] && continue
            actual_dest=$(resolve_bind_path "$mpath")
            check_mount_safety "$actual_dest" "Bind Mount 恢复目标 ($mpath)" 0
            bind_uncomp_kb=$(get_uncompressed_kb "bind" "$mpath" "$BACKUP_DIR/docker_bind_mounts.tar.gz")
            chk_d="$actual_dest"
            while [ ! -d "$chk_d" ] && [ "$chk_d" != "/" ] && [ "$chk_d" != "." ]; do
                p_d=$(dirname "$chk_d")
                [ "$p_d" = "$chk_d" ] && break
                chk_d="$p_d"
            done
            b_abs=$(cd "$chk_d" 2>/dev/null && pwd -P)
            if [ -z "$b_abs" ]; then
                log_error "无法解析 Bind Mount 恢复目标 [$mpath] 绝对路径: $actual_dest"
                exit 1
            fi
            df_b=$(df -P "$b_abs" 2>/dev/null || true)
            b_pt=$(echo "$df_b" | awk 'NR==2{print $6}')
            b_dev=$(echo "$df_b" | awk 'NR==2{print $1}')
            b_avail=$(echo "$df_b" | awk 'NR==2{print $4}')
            echo "$b_pt	$b_dev	$b_avail	$bind_uncomp_kb" >> "$RESTORE_MNT_REQS"
        done < "$BIND_MANIFEST"
    fi

    # 按目标文件系统挂载点 (m_pt) 汇总空间需求并核验
    awk -F'\t' '{
        pt = $1;
        dev[pt] = $2;
        avail[pt] = $3;
        sum_need[pt] += $4;
    } END {
        for (pt in sum_need) {
            printf "%s\t%s\t%s\t%s\n", pt, dev[pt], avail[pt], sum_need[pt];
        }
    }' "$RESTORE_MNT_REQS" | while IFS='	' read -r c_pt c_dev c_avail c_sum_need || [ -n "$c_pt" ]; do
        [ -z "$c_pt" ] && continue
        case "$c_avail" in ''|*[!0-9]*) c_avail=0 ;; esac
        case "$c_sum_need" in ''|*[!0-9]*) c_sum_need=0 ;; esac
        total_need=$((c_sum_need + 10240))
        if [ "$c_avail" -lt "$total_need" ]; then
            log_error "目标挂载点 $c_pt (设备: $c_dev) 存储空间不足！全部恢复组件展开汇总所需: ${total_need}KB (包含展开数据 ${c_sum_need}KB + 冗余 10240KB)，当前可用: ${c_avail}KB"
            rm -f "$RESTORE_MNT_REQS"
            exit 1
        fi
        log_info "目标挂载点 $c_pt 容量安全核验通过: 汇总展开所需 ${total_need}KB <= 可用 ${c_avail}KB"
    done
    rm -f "$RESTORE_MNT_REQS"

    # 3. 恢复前确认 dockerd 已停止
    INIT_DOCKERD="$(get_sys_path /etc/init.d/dockerd)"
    if pgrep -x dockerd >/dev/null 2>&1; then
        log_error "dockerd 守护进程正在运行中！恢复数据与配置前必须确保 dockerd 已停止！"
        exit 1
    fi

    # 4. 恢复统一命名的配置文件并同步 DataRoot
    ETC_DIR="$(get_sys_path /etc)"
    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"
    CONFIG_SRC="$BACKUP_DIR/config"

    if [ -d "$CONFIG_SRC" ]; then
        log_info "正在恢复 Docker 配置文件..."
        mkdir -p "$ETC_DIR/docker" "$CONFIG_DIR_HOST"

        if [ -d "$CONFIG_SRC/etc_docker" ]; then
            cp -r "$CONFIG_SRC/etc_docker/." "$ETC_DIR/docker/" || { log_error "恢复 etc_docker 失败！"; exit 1; }
        elif [ -d "$CONFIG_SRC/docker" ]; then
            cp -r "$CONFIG_SRC/docker/." "$ETC_DIR/docker/" || { log_error "恢复 docker 失败！"; exit 1; }
        fi

        if [ -f "$CONFIG_SRC/config_dockerd" ]; then
            cp "$CONFIG_SRC/config_dockerd" "$CONFIG_DIR_HOST/dockerd" || { log_error "恢复 config_dockerd 失败！"; exit 1; }
        elif [ -f "$CONFIG_SRC/dockerd" ]; then
            cp "$CONFIG_SRC/dockerd" "$CONFIG_DIR_HOST/dockerd" || { log_error "恢复 dockerd 失败！"; exit 1; }
        fi

        if [ -f "$CONFIG_SRC/config_dockerman" ]; then
            cp "$CONFIG_SRC/config_dockerman" "$CONFIG_DIR_HOST/dockerman" || { log_error "恢复 config_dockerman 失败！"; exit 1; }
        elif [ -f "$CONFIG_SRC/dockerman" ]; then
            cp "$CONFIG_SRC/dockerman" "$CONFIG_DIR_HOST/dockerman" || { log_error "恢复 dockerman 失败！"; exit 1; }
        fi

        # 同步 UCI 中的 data_root 为新目标目录
        if command -v uci >/dev/null 2>&1 && [ -f "$CONFIG_DIR_HOST/dockerd" ]; then
            UCI_CMD="uci"
            [ -n "$SYS_ROOT" ] && UCI_CMD="uci -c $CONFIG_DIR_HOST"
            $UCI_CMD set dockerd.globals.data_root="$TARGET_DATA_ABS" || { log_error "UCI 设置 data_root 失败"; exit 1; }
            $UCI_CMD commit dockerd || { log_error "UCI commit dockerd 失败"; exit 1; }
        fi

        # 同步 daemon.json
        if [ -f "$ETC_DIR/docker/daemon.json" ] && command -v sed >/dev/null 2>&1; then
            sed -i "s|\"data-root\": *\"[^\"]*\"|\"data-root\": \"$TARGET_DATA_ABS\"|g" "$ETC_DIR/docker/daemon.json"
        fi
    fi

    # 5. 严格解压顺序：先解压 Compose 目录结构，后解压 Bind Mounts，确保冷备持久化数据绝不被旧 Compose 包覆盖
    if [ -f "$COMPOSE_MANIFEST" ]; then
        log_info "正在恢复 Compose 编排项目至原路径..."
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            proj_tar="$BACKUP_DIR/compose/${proj_name}.tar.gz"
            dest_dir=$(resolve_bind_path "$orig_dir")
            mkdir -p "$dest_dir"
            tar -xzf "$proj_tar" -C "$dest_dir" || {
                log_error "恢复 Compose 项目 $proj_name 失败！"
                exit 1
            }
            log_info "已恢复 Compose 项目 [$proj_name] 到原路径: $dest_dir"
        done < "$COMPOSE_MANIFEST"
    fi

    # 6. 恢复 Bind Mounts 数据至宿主机原路径（在 Compose 之后解压，权威覆盖持久化数据）
    if [ -f "$BACKUP_DIR/docker_bind_mounts.tar.gz" ]; then
        log_info "正在恢复 Bind Mounts 数据至原路径..."
        DEST_ROOT="/"
        [ -n "$SYS_ROOT" ] && DEST_ROOT="$SYS_ROOT"
        tar -xzf "$BACKUP_DIR/docker_bind_mounts.tar.gz" -C "$DEST_ROOT" || {
            log_error "解压 Bind Mounts 失败！"
            exit 1
        }
    fi

    # 7. 恢复 Named Volumes 至目标 DataRoot
    log_info "正在恢复 Named Volumes 至: $TARGET_DATA_ABS..."
    tar -xzf "$BACKUP_DIR/docker_volumes.tar.gz" -C "$TARGET_DATA_ABS" || {
        log_error "解压 Named Volumes 失败！"
        exit 1
    }

    # 8. 启动 dockerd 并按原记录恢复开机自启
    if [ -x "$INIT_DOCKERD" ]; then
        log_info "正在启动 dockerd 服务..."
        "$INIT_DOCKERD" start || {
            log_error "启动 dockerd 服务失败！请检查系统日志。"
            exit 1
        }

        # 等待 dockerd 响应
        if command -v docker >/dev/null 2>&1; then
            WAIT_N=0
            while [ $WAIT_N -lt 15 ]; do
                if docker info >/dev/null 2>&1; then
                    break
                fi
                WAIT_N=$((WAIT_N + 1))
                sleep 1
            done
            if [ $WAIT_N -ge 15 ]; then
                log_error "dockerd 启动后未在预期时间内响应！"
                exit 1
            fi
        fi

        if [ -f "$BACKUP_DIR/docker_autostart.state" ]; then
            WAS_ENABLED=$(cat "$BACKUP_DIR/docker_autostart.state" 2>/dev/null || echo "0")
            if [ "$WAS_ENABLED" = "1" ]; then
                log_info "正在恢复 dockerd 开机自启..."
                "$INIT_DOCKERD" enable || {
                    log_error "恢复 dockerd 自启动失败！"
                    exit 1
                }
            fi
        fi
    fi

    # 9. 仅拉起本次备份记录的 Compose 项目（严格使用记录的项目名、配置文件与环境变量文件）
    if [ -f "$COMPOSE_MANIFEST" ]; then
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            dest_dir=$(resolve_bind_path "$orig_dir")
            if [ -d "$dest_dir" ]; then
                log_info "启动记录的 Compose 项目: $proj_name (目录: $dest_dir)..."

                actual_cfg=""
                if [ -n "$config_file" ]; then
                    actual_cfg=$(resolve_bind_path "$config_file")
                    if [ ! -f "$actual_cfg" ] && [ -f "$dest_dir/docker-compose.yml" ]; then
                        actual_cfg="$dest_dir/docker-compose.yml"
                    elif [ ! -f "$actual_cfg" ] && [ -f "$dest_dir/compose.yaml" ]; then
                        actual_cfg="$dest_dir/compose.yaml"
                    fi
                fi

                compose_cmd=""
                if command -v docker-compose >/dev/null 2>&1; then
                    compose_cmd="docker-compose"
                elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
                    compose_cmd="docker compose"
                fi

                if [ -n "$compose_cmd" ]; then
                    run_cmd="$compose_cmd -p \"$proj_name\""
                    if [ -n "$actual_cfg" ] && [ -f "$actual_cfg" ]; then
                        run_cmd="$run_cmd -f \"$actual_cfg\""
                    fi
                    if [ -f "$dest_dir/.env" ]; then
                        run_cmd="$run_cmd --env-file \"$dest_dir/.env\""
                    fi
                    run_cmd="$run_cmd up -d"

                    log_info "执行 Compose 启动命令: $run_cmd"
                    (cd "$dest_dir" && eval "$run_cmd") || {
                        log_error "启动 Compose 项目 $proj_name 失败！"
                        exit 1
                    }
                else
                    log_warn "未找到 docker-compose 或 docker compose 命令，跳过 Compose 项目 $proj_name 启动"
                fi
            fi
        done < "$COMPOSE_MANIFEST"
    fi

    # 10. 重建独立容器
    if [ -d "$BACKUP_DIR/standalone" ]; then
        STANDALONE_DIR="$BACKUP_DIR/standalone"
        for rscript in "$STANDALONE_DIR"/recreate_*.sh; do
            [ -f "$rscript" ] || continue
            log_info "执行独立容器重建: $(basename "$rscript")..."
            STANDALONE_DIR="$STANDALONE_DIR" sh "$rscript" || {
                log_error "重建容器脚本 $(basename "$rscript") 执行失败！"
                exit 1
            }
        done
    fi

    # 11. 检查是否存在导出的数据库文件，提示用户按需导入
    if [ -d "$BACKUP_DIR/databases" ] && ls "$BACKUP_DIR/databases"/*.sql >/dev/null 2>&1; then
        log_info "检测到备份中存在应用级数据库转储文件 ($BACKUP_DIR/databases/):"
        for dbf in "$BACKUP_DIR/databases"/*.sql; do
            [ -f "$dbf" ] && log_info "  - $(basename "$dbf")"
        done
        log_info "若需恢复数据库逻辑数据，请在容器稳定运行后执行对应 docker exec 导入。"
    fi

    log_info "Docker 数据与服务已完整恢复成功！"
}

# -----------------------------------------------------------------------------
# 4. 升级后 NSS 遗留项清理 (clean_nss)
# -----------------------------------------------------------------------------
do_clean_nss() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    require_cmd uci

    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"
    INIT_FIREWALL="$(get_sys_path /etc/init.d/firewall)"
    UCI_CMD="uci"
    [ -n "$SYS_ROOT" ] && UCI_CMD="uci -c $CONFIG_DIR_HOST"

    if $UCI_CMD -q get firewall.qcanssecm >/dev/null 2>&1; then
        SEC_TYPE=$($UCI_CMD -q get firewall.qcanssecm || true)
        SCRIPT_PATH=$($UCI_CMD -q get firewall.qcanssecm.path || true)
        log_info "发现 firewall.qcanssecm (节类型: $SEC_TYPE, 路径: $SCRIPT_PATH)"

        # 必须同时满足：节类型为 include，路径精确匹配已确认的旧 NSS 脚本。空路径、未知路径或同名 rule 绝不删除
        if [ "$SEC_TYPE" != "include" ]; then
            log_warn "firewall.qcanssecm 节类型为 '$SEC_TYPE' (非 include)，属于自定义规则，严禁删除！"
            return 0
        fi

        if [ -z "$SCRIPT_PATH" ]; then
            log_warn "firewall.qcanssecm path 为空，未知目标，保留不做修改。"
            return 0
        fi

        case "$SCRIPT_PATH" in
            /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss|/etc/init.d/qca-nss-ecm)
                log_info "确认属于已废弃旧版 NSS include 脚本 ($SCRIPT_PATH)，执行安全清理..."
                # 备份旧防火墙配置以防万一（保留配置升级要求：备份后只清理对应遗留节）
                if [ -f "$CONFIG_DIR_HOST/firewall" ]; then
                    BAK_FW="$CONFIG_DIR_HOST/firewall.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo 'old')"
                    cp "$CONFIG_DIR_HOST/firewall" "$BAK_FW"
                    log_info "已自动备份当前防火墙配置至: $BAK_FW"
                fi
                $UCI_CMD delete firewall.qcanssecm
                $UCI_CMD commit firewall
                [ -x "$INIT_FIREWALL" ] && "$INIT_FIREWALL" reload >/dev/null 2>&1 || true
                log_info "NSS 废弃 include 项已成功清理。"
                ;;
            *)
                log_warn "firewall.qcanssecm 指向未知脚本 ($SCRIPT_PATH)，保留不做修改。"
                ;;
        esac
    else
        log_info "未检测到废弃 NSS 防火墙钩子 (firewall.qcanssecm)"
    fi
}

# -----------------------------------------------------------------------------
# 5. 升级后运行时验收 (verify_runtime)
# 验收顺序：1) 网络连通性与 PassWall2 代理 -> 2) 软硬件加速 (PPE Flowtable) -> 3) Docker 网络与防火墙策略
# -----------------------------------------------------------------------------
do_verify_runtime() {
    CHECK_TARGET="all"

    while [ $# -gt 0 ]; do
        case "$1" in
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            all|ppe|docker|passwall)
                CHECK_TARGET="$1"
                shift
                ;;
            *)
                log_error "未知验收参数: $1"
                exit 1
                ;;
        esac
    done

    FAILED=0

    # 1. 验证网络连通性与 PassWall2 代理核心与握手
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "passwall" ]; then
        log_info "=== 验证 PassWall2 代理核心与握手 ==="
        PW_CORE=""
        if pgrep -x sing-box >/dev/null 2>&1; then
            PW_CORE="sing-box"
        elif pgrep -x xray >/dev/null 2>&1; then
            PW_CORE="xray"
        fi

        if [ -z "$PW_CORE" ]; then
            log_error "PassWall2 核心进程 (sing-box / xray) 未在运行！"
            FAILED=1
        else
            log_info "PassWall2 活动核心: $PW_CORE"
            VAR_PW_DIR="$(get_sys_path /var/etc/passwall2)"
            SOCKS_PORT=""
            VALID_JSON=1

            # 1. 查找运行进程实际命令行与对应的配置文件路径（支持 ACL 子目录与任意指定配置）
            CANDIDATE_CONFIGS=""
            PW_PIDS=$(pgrep -x "$PW_CORE" 2>/dev/null || pgrep "$PW_CORE" 2>/dev/null || pidof "$PW_CORE" 2>/dev/null || true)
            for p_id in $PW_PIDS; do
                cmd_file="$(get_sys_path /proc)/$p_id/cmdline"
                [ ! -f "$cmd_file" ] && cmd_file="/proc/$p_id/cmdline"
                if [ -f "$cmd_file" ]; then
                    p_args=$(tr '\0' '\n' < "$cmd_file" 2>/dev/null || true)
                    for pa in $p_args; do
                        case "$pa" in
                            *.json)
                                real_cfg=$(get_sys_path "$pa")
                                [ -f "$real_cfg" ] && CANDIDATE_CONFIGS="$CANDIDATE_CONFIGS $real_cfg"
                                ;;
                        esac
                    done
                fi
            done

            # 2. 辅以 ps 输出解析命令行中的 .json 配置文件路径
            if command -v ps >/dev/null 2>&1; then
                ps_lines=$(ps -w 2>/dev/null | grep -E "$PW_CORE" | grep -oE "(/[^[:space:]]+\.json)" || true)
                for pl in $ps_lines; do
                    real_cfg=$(get_sys_path "$pl")
                    [ -f "$real_cfg" ] && CANDIDATE_CONFIGS="$CANDIDATE_CONFIGS $real_cfg"
                done
            fi

            # 3. 辅以 /var/etc/passwall2 目录下（含 ACL 子目录及所有深层子目录）所有 JSON 文件的递归扫描
            if [ -d "$VAR_PW_DIR" ]; then
                pw_all_json=$(find "$VAR_PW_DIR" -type f -name "*.json" 2>/dev/null || true)
                for f_cfg in $pw_all_json; do
                    CANDIDATE_CONFIGS="$CANDIDATE_CONFIGS $f_cfg"
                done
            fi

            # 逐一校验候选配置并提取 inbounds SOCKS 本地监听端口
            CHECKED_FILES=""
            for cfg in $CANDIDATE_CONFIGS; do
                [ -f "$cfg" ] || continue
                case " $CHECKED_FILES " in
                    *" $cfg "*) continue ;;
                esac
                CHECKED_FILES="$CHECKED_FILES $cfg"

                # 校验 JSON 语法
                if command -v jq >/dev/null 2>&1; then
                    if ! jq empty "$cfg" >/dev/null 2>&1; then
                        log_error "PassWall2 核心配置文件语法异常 ($cfg)！"
                        VALID_JSON=0
                    fi
                fi
                if [ -z "$SOCKS_PORT" ]; then
                    if command -v jq >/dev/null 2>&1; then
                        SOCKS_PORT=$(jq -r '.inbounds[]? | select((.protocol? == "socks") or (.type? == "socks") or ((.tag? // "") | test("socks"; "i"))) | (.listen_port // .port // empty)' "$cfg" 2>/dev/null | head -n 1 || true)
                    fi
                    if [ -z "$SOCKS_PORT" ]; then
                        # 使用 awk 严格在 inbounds 节区内提取 socks 监听端口，杜绝截取 outbounds 远程服务器端口（支持嵌套对象与 port/protocol 任意出现顺序）
                        SOCKS_PORT=$(awk '
                            BEGIN {
                                in_inb = 0
                                brace_depth = 0
                                curr_port = ""
                                is_socks = 0
                            }
                            /"inbounds"[[:space:]]*:/ {
                                in_inb = 1
                            }
                            in_inb {
                                n_open = split($0, d1, /\{/) - 1
                                n_close = split($0, d2, /\}/) - 1

                                if (brace_depth > 0 || n_open > 0) {
                                    if ($0 ~ /"(protocol|type)"[[:space:]]*:[[:space:]]*"socks"/ || $0 ~ /"tag"[[:space:]]*:[[:space:]]*"[^"]*socks[^"]*"/) {
                                        is_socks = 1
                                    }
                                    if ($0 ~ /"(listen_port|port)"[[:space:]]*:[[:space:]]*[0-9]+/) {
                                        match($0, /"(listen_port|port)"[[:space:]]*:[[:space:]]*[0-9]+/)
                                        if (RLENGTH > 0) {
                                            str = substr($0, RSTART, RLENGTH)
                                            split(str, arr, ":")
                                            gsub(/[[:space:]]/, "", arr[2])
                                            curr_port = arr[2]
                                        }
                                    }
                                }

                                if (brace_depth == 0 && n_open > 0) {
                                    brace_depth += n_open
                                    brace_depth -= n_close
                                } else if (brace_depth > 0) {
                                    brace_depth += n_open
                                    brace_depth -= n_close
                                }

                                if (brace_depth == 0 && (n_open > 0 || n_close > 0)) {
                                    if (is_socks == 1 && curr_port != "") {
                                        print curr_port
                                        exit
                                    }
                                    curr_port = ""
                                    is_socks = 0
                                }

                                if (brace_depth == 0 && $0 ~ /\]/) {
                                    in_inb = 0
                                }
                            }
                        ' "$cfg" 2>/dev/null || true)
                    fi
                fi
            done

            if [ "$VALID_JSON" -ne 1 ]; then
                FAILED=1
            fi

            if [ -z "$SOCKS_PORT" ]; then
                log_error "未能从 inbounds 配置中定位 PassWall2 本地 SOCKS 监听端口 (禁止截取 outbounds 或盲猜默认 1080)！"
                FAILED=1
            else
                log_info "定位到活动核心 SOCKS 本地监听端口: $SOCKS_PORT"
                if ! command -v curl >/dev/null 2>&1; then
                    log_error "缺少 curl 工具，无法发起 SOCKS 代理握手测试！"
                    FAILED=1
                else
                    # 真实 TLS 握手与连通性校验
                    log_info "通过本地 SOCKS 端口 ($SOCKS_PORT) 发起真实 TLS 握手测试 (https://www.google.com)..."
                    if curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s -I https://www.google.com >/dev/null 2>&1; then
                        log_info "PassWall2 代理握手验证成功！"
                    else
                        log_error "PassWall2 代理握手失败，未能通过 SOCKS 端口建立 TLS 连接！(注: 单纯 Ping 无法证明 TLS 成功)"
                        FAILED=1
                    fi

                    # 出口 IP 验证
                    log_info "核验代理节点公网出口 IP..."
                    EXIT_IP=$(curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 8 -s https://api.ipify.org 2>/dev/null || curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 8 -s http://icanhazip.com 2>/dev/null || true)
                    if [ -n "$EXIT_IP" ]; then
                        log_info "代理出口 IP 识别成功: $EXIT_IP"
                    fi

                    # 国内直连分流验证
                    log_info "验证国内直连分流 (baidu.com)..."
                    if curl -m 5 -s -I https://www.baidu.com >/dev/null 2>&1; then
                        log_info "国内直连分流测试: 正常"
                    else
                        log_warn "国内直连访问超时，请核实 WAN 口 DNS 与路由"
                    fi
                fi

                # 核心日志排查（排查 TLS 证书、鉴权或握手失败）
                LOG_CHECK=$(logread -e passwall2 2>/dev/null || dmesg 2>/dev/null || true)
                if echo "$LOG_CHECK" | grep -qiE "(handshake.*fail|certificate.*invalid|authentication.*fail|invalid.*user)"; then
                    log_error "PassWall2 日志中检测到 TLS 握手或鉴权错误记录！"
                    FAILED=1
                fi
            fi
        fi
    fi

    # 2. 验证 PPE 硬件加速与 Flowtable
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "ppe" ]; then
        log_info "=== 验证 PPE 硬件加速与 Flowtable ==="
        PPE_OK=0
        HAS_HW_OFFLOAD=0
        HAS_SW_FLOWTABLE=0

        if command -v nft >/dev/null 2>&1; then
            RULESET=$(nft list ruleset 2>/dev/null || nft list tables 2>/dev/null || true)
            if echo "$RULESET" | grep -q "flowtable"; then
                HAS_SW_FLOWTABLE=1
                if echo "$RULESET" | grep -qE "flags[[:space:]]+offload|flags[[:space:]]*=[[:space:]]*\{?[[:space:]]*(hw_offload|offload)[[:space:]]*\}?|hw_offload"; then
                    HAS_HW_OFFLOAD=1
                fi
            fi
        fi

        DMESG_TEXT=$(dmesg 2>/dev/null || true)
        LOGREAD_TEXT=$(logread -e ppe 2>/dev/null || logread 2>/dev/null || true)
        ALL_KERNEL_LOG="$DMESG_TEXT $LOGREAD_TEXT"

        PPE_DRIVER_FAIL=0
        if echo "$ALL_KERNEL_LOG" | grep -qiE "(ppe|flowtable|qcom-ppe).*(probe.*fail|fail|error|disabled|cannot|timed out)"; then
            log_error "内核/系统日志检测到 PPE/Flowtable 驱动报错或探测失败 (probe failed)，硬件加速未正常生效！"
            PPE_DRIVER_FAIL=1
        fi

        if [ "$PPE_DRIVER_FAIL" -eq 1 ]; then
            log_error "PPE 硬件加速异常：驱动探测或初始化失败！"
            PPE_OK=0
            FAILED=1
        elif [ "$HAS_HW_OFFLOAD" -eq 1 ]; then
            log_info "PPE 硬件加速状态: 已生效 (nftables flowtable 包含 hw_offload 硬件加速标志)"
            PPE_OK=1
        elif [ "$HAS_SW_FLOWTABLE" -eq 1 ]; then
            log_error "仅检测到软件 Flowtable 流表，缺少 hw_offload 硬件卸载标志！Qualcomm PPE 硬件加速未生效！"
            PPE_OK=0
            FAILED=1
        else
            log_error "未检测到 Flowtable 流表规则或 PPE 硬件加速未开启！"
            PPE_OK=0
            FAILED=1
        fi
    fi

    # 3. 验证 Docker 容器网络、防火墙后端与 WAN 边界策略
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "docker" ]; then
        log_info "=== 验证 Docker 容器网络、防火墙后端与端口映射 ==="
        if ! command -v docker >/dev/null 2>&1; then
            log_error "Docker 未安装或命令不可用！"
            FAILED=1
        else
            # 3a. 识别实际防火墙后端 (iptables-legacy / iptables-nft / nftables)
            FW_BACKEND="unknown"
            if command -v iptables >/dev/null 2>&1; then
                IPT_VER=$(iptables -V 2>/dev/null || true)
                if echo "$IPT_VER" | grep -qi "nf_tables"; then
                    FW_BACKEND="iptables-nft (兼容层)"
                elif echo "$IPT_VER" | grep -qi "legacy"; then
                    FW_BACKEND="iptables-legacy"
                else
                    FW_BACKEND="iptables"
                fi
            elif command -v nft >/dev/null 2>&1; then
                FW_BACKEND="nftables (原生)"
            fi
            log_info "检测到当前防火墙后端: $FW_BACKEND"

            # 3b. 检查 filter / nat 表中的 Docker 链
            CHAIN_FOUND=0
            if command -v iptables >/dev/null 2>&1; then
                if iptables -t filter -n -L DOCKER >/dev/null 2>&1 || iptables -t nat -n -L DOCKER >/dev/null 2>&1; then
                    CHAIN_FOUND=1
                    log_info "已确认 iptables filter/nat 表中的 DOCKER 链规则正常就绪"
                fi
            fi
            if [ "$CHAIN_FOUND" -eq 0 ] && command -v nft >/dev/null 2>&1; then
                if nft list tables 2>/dev/null | grep -qE "filter|nat|fw4"; then
                    if nft list ruleset 2>/dev/null | grep -qi "docker"; then
                        CHAIN_FOUND=1
                        log_info "已确认 nftables 规则集中的 Docker 链规则正常就绪"
                    fi
                fi
            fi
            if [ "$CHAIN_FOUND" -eq 0 ]; then
                log_warn "未能在防火墙 filter/nat 表中检测到 DOCKER 链，请确认 dockerd 已启用 iptables 支持"
            fi

            # 3c. 出网 TCP / HTTP 测试 (Egress)
            log_info "测试 Docker 容器外网出网 (TCP/HTTP)..."
            if docker run --rm alpine sh -c "wget -q -T 5 -O - http://connectivitycheck.gstatic.com/generate_204 || wget -q -T 5 -O - http://www.baidu.com" >/dev/null 2>&1; then
                log_info "Docker 容器外网出网测试: 正常"
            else
                log_error "Docker 容器外网出网测试失败！"
                FAILED=1
            fi

            # 3d. 端口映射测试
            log_info "测试 Docker 端口映射与 NAT 转发..."
            PORT_OK=0
            CID=$(docker run -d -p 127.0.0.1:18888:80 alpine sh -c "echo -e 'HTTP/1.1 200 OK\r\n\r\nPORT_OK' | nc -l -p 80" 2>/dev/null || true)
            if [ -n "$CID" ]; then
                sleep 1
                RESP=$(curl -m 3 -s http://127.0.0.1:18888 2>/dev/null || wget -q -T 3 -O - http://127.0.0.1:18888 2>/dev/null || true)
                if echo "$RESP" | grep -q "PORT_OK"; then
                    PORT_OK=1
                    log_info "Docker 容器端口映射与本地访问: 正常"
                fi
                docker rm -f "$CID" >/dev/null 2>&1 || true
            fi
            if [ "$PORT_OK" -ne 1 ]; then
                log_error "Docker 端口映射验证失败！"
                FAILED=1
            fi

            # 3e. 核验 WAN 边界阻断策略 (确认 WAN 入站无法未经授权直连 Docker 端口)
            log_info "核验 WAN 边界阻断策略..."
            if command -v iptables >/dev/null 2>&1; then
                FWD_POLICY=$(iptables -S FORWARD 2>/dev/null | head -n 1 || true)
                if echo "$FWD_POLICY" | grep -qE -- "-P FORWARD (DROP|REJECT)"; then
                    log_info "iptables FORWARD 默认策略为 DROP/REJECT，WAN 入站阻断安全"
                fi
            fi
            if command -v nft >/dev/null 2>&1; then
                if nft list chain inet fw4 forward 2>/dev/null | grep -qiE "drop|reject"; then
                    log_info "nftables fw4 forward 包含 drop/reject 策略，WAN 边界阻断安全"
                fi
            fi
        fi
    fi

    if [ "$FAILED" -ne 0 ]; then
        log_error "运行时验收未完全通过，存在失败项！"
        exit 1
    fi
    log_info "运行时验收全部通过！"
}

# -----------------------------------------------------------------------------
# 主入口调度
# -----------------------------------------------------------------------------
case "${1:-}" in
    backup)
        shift
        do_backup "$@"
        ;;
    restore)
        shift
        do_restore "$@"
        ;;
    precheck)
        shift
        do_precheck "$@"
        ;;
    clean-nss)
        shift
        do_clean_nss "$@"
        ;;
    verify)
        shift
        do_verify_runtime "$@"
        ;;
    *)
        echo "用法: $0 {backup|restore|precheck|clean-nss|verify} [参数...]"
        exit 1
        ;;
esac
