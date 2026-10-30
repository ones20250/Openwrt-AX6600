#!/bin/sh
# Real Docker End-to-End Drill Script for AX6600 Docker Upgrade Helper
# Designed to run in isolated Docker environments (e.g. DinD or dedicated test runners)
# NEVER damages or stops host business containers.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
HELPER_SCRIPT="$REPO_ROOT/Scripts/docker_upgrade_helper.sh"

log() {
    echo "[DRILL] $*"
}

log_err() {
    echo "[DRILL ERROR] $*" >&2
}

# 1. 检查 Docker 命令基础可用性
if ! command -v docker >/dev/null 2>&1; then
    log_err "Docker 未安装或不在 PATH 中，跳过真实 Docker 演练。"
    exit 0
fi

ISOLATED_MODE=0
ALLOW_HOST=0
for arg in "$@"; do
    case "$arg" in
        --isolated)
            ISOLATED_MODE=1
            ;;
        --allow-host)
            ALLOW_HOST=1
            ;;
    esac
done

if [ "${AX6600_DRILL_ISOLATED:-0}" = "1" ]; then
    ISOLATED_MODE=1
fi

# 2. 宿主安全防护：严禁在共享业务 Docker 宿主直接运行 helper 停机备份
if [ "$ISOLATED_MODE" -eq 0 ] && [ "$ALLOW_HOST" -eq 0 ]; then
    if ! docker info >/dev/null 2>&1; then
        log_err "Docker 守护进程未运行或无权限访问，跳过真实 Docker 演练。"
        exit 0
    fi
    RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null || true)
    if [ -n "$RUNNING_CONTAINERS" ]; then
        log "检测到当前宿主机存在运行中的业务容器 ($(echo "$RUNNING_CONTAINERS" | wc -w) 个)。"
        log "为防止 helper 停机冷备中断宿主机其他业务容器，自动启动专用隔离 DinD (Docker-in-Docker) 容器执行演练..."
    else
        log "提示: 当前机器未指定 --allow-host，为保护宿主环境，自动启动专用隔离 DinD (Docker-in-Docker) 容器执行演练..."
    fi
    exec docker run --rm --privileged \
        -e AX6600_DRILL_ISOLATED=1 \
        -v "$REPO_ROOT:/workspace" \
        -w /workspace \
        docker:dind sh -c '
            if command -v apk >/dev/null 2>&1; then
                apk add --no-cache e2fsprogs >/dev/null 2>&1 || true
            fi
            /workspace/tests/drill_real_docker.sh --isolated
        '
fi

# 3. 准备隔离存储挂载点（绝不在 /tmp 下建立备份，防止被 check_mount_safety 拒绝）
DRILL_LOOP_DEV=""
DRILL_LOOP_MNT=""
DRILL_ROOT=""

cleanup_drill_storage() {
    if [ -n "$DRILL_LOOP_MNT" ] && [ -d "$DRILL_LOOP_MNT" ]; then
        umount "$DRILL_LOOP_MNT" 2>/dev/null || true
        rm -rf "$DRILL_LOOP_MNT" 2>/dev/null || true
    fi
    if [ -n "$DRILL_LOOP_DEV" ] && [ -f "$DRILL_LOOP_DEV" ]; then
        rm -f "$DRILL_LOOP_DEV" 2>/dev/null || true
    fi
}

if [ -n "${DRILL_STORAGE_ROOT:-}" ] && [ -d "$DRILL_STORAGE_ROOT" ]; then
    DRILL_ROOT="$DRILL_STORAGE_ROOT/ax6600_drill_$$"
elif [ "$(id -u)" = "0" ] && command -v mount >/dev/null 2>&1 && command -v truncate >/dev/null 2>&1 && (command -v mkfs.ext4 >/dev/null 2>&1 || command -v mkfs.ext2 >/dev/null 2>&1 || command -v mke2fs >/dev/null 2>&1); then
    # 使用 loopback ext4 独立挂载，既不污染宿主，又完美满足非 rootfs / 非 tmpfs 外部存储安全核验
    DRILL_LOOP_DEV="/var/run/ax6600_drill_loop_$$.img"
    DRILL_LOOP_MNT="/mnt/ax6600_drill_$$"
    mkdir -p /var/run "$DRILL_LOOP_MNT"
    truncate -s 256M "$DRILL_LOOP_DEV"
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        mkfs.ext4 -F "$DRILL_LOOP_DEV" >/dev/null 2>&1
    elif command -v mkfs.ext2 >/dev/null 2>&1; then
        mkfs.ext2 -F "$DRILL_LOOP_DEV" >/dev/null 2>&1
    else
        mke2fs -F "$DRILL_LOOP_DEV" >/dev/null 2>&1
    fi
    mount -o loop "$DRILL_LOOP_DEV" "$DRILL_LOOP_MNT"
    DRILL_ROOT="$DRILL_LOOP_MNT/drill_root"
else
    # 查找是否有其他非 rootfs / 非 tmpfs 挂载点
    external_cand=$(df -P 2>/dev/null | awk '$6 ~ /^\/(mnt|media|opt|data)/ && $1 !~ /(overlay|rootfs|tmpfs|ramfs|shm)/ {print $6}' | head -n 1 || true)
    if [ -n "$external_cand" ] && [ -d "$external_cand" ]; then
        DRILL_ROOT="$external_cand/ax6600_drill_$$"
    else
        log_err "无法创建隔离 ext4 loop 挂载点，且未找到合规的独立外部挂载介质。"
        log_err "请以 root 身份运行以允许 loop 挂载，或通过环境变量 DRILL_STORAGE_ROOT 指定非 rootfs/tmpfs 挂载目录！"
        exit 1
    fi
fi

DRILL_BACKUP="$DRILL_ROOT/backup_target"
DRILL_RESTORE_DATA="$DRILL_ROOT/restored_dataroot"
DRILL_SYS_ROOT="$DRILL_ROOT/mock_sys_root"
DRILL_BIN="$DRILL_ROOT/bin"
DRILL_SOCK="$DRILL_ROOT/dockerd.sock"
DRILL_PID_FILE="$DRILL_ROOT/dockerd.pid"
DRILL_INIT_DATA="$DRILL_ROOT/init_dataroot"

# 统一路径映射：将持久化 Bind 数据置于 SYS_ROOT 下，确保 resolve_bind_path 与绝对路径完全对应
DRILL_BIND_SRC="$DRILL_SYS_ROOT/host_bind_data"
DRILL_COMPOSE_DIR="$DRILL_SYS_ROOT/compose_proj"
export DRILL_SYS_ROOT

# 固定专属 Docker 端点，严禁使用系统共享套接字
export DOCKER_HOST="unix://$DRILL_SOCK"

mkdir -p "$DRILL_BACKUP" "$DRILL_RESTORE_DATA" "$DRILL_BIND_SRC" "$DRILL_COMPOSE_DIR" "$DRILL_SYS_ROOT" "$DRILL_BIN" "$DRILL_INIT_DATA"

# 4. 初始化模拟 OpenWrt 服务脚本与工具（解决普通 Linux 缺失 /etc/init.d/dockerd 与 uci 的问题）
cat << EOF > "$DRILL_SYS_ROOT/etc_init_dockerd"
#!/bin/sh
cmd="\$1"
STATE_FILE="$DRILL_SYS_ROOT/dockerd_enabled"
CONFIG_FILE="$DRILL_SYS_ROOT/etc/config/dockerd.data_root"
PID_FILE="$DRILL_PID_FILE"
SOCK_FILE="$DRILL_SOCK"

case "\$cmd" in
    enabled)
        [ "\$(cat "\$STATE_FILE" 2>/dev/null || echo 0)" = "1" ] && exit 0 || exit 1
        ;;
    enable)
        echo "1" > "\$STATE_FILE"
        exit 0
        ;;
    disable)
        echo "0" > "\$STATE_FILE"
        exit 0
        ;;
    stop)
        if [ -f "\$PID_FILE" ]; then
            p=\$(cat "\$PID_FILE" 2>/dev/null || true)
            if [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null; then
                kill -TERM "\$p" 2>/dev/null || true
                n=0
                while [ \$n -lt 30 ]; do
                    if ! kill -0 "\$p" 2>/dev/null; then
                        break
                    fi
                    n=\$((n + 1))
                    sleep 1
                done
                if kill -0 "\$p" 2>/dev/null; then
                    kill -9 "\$p" 2>/dev/null || true
                    sleep 1
                fi
            fi
            rm -f "\$PID_FILE" "\$SOCK_FILE" 2>/dev/null || true
        fi
        exit 0
        ;;
    start|restart)
        dr="$DRILL_INIT_DATA"
        if [ -f "\$CONFIG_FILE" ]; then
            cfg_dr=\$(cat "\$CONFIG_FILE" 2>/dev/null || echo "")
            [ -n "\$cfg_dr" ] && dr="\$cfg_dr"
        fi
        mkdir -p "\$dr"
        if [ -f "\$PID_FILE" ]; then
            old_p=\$(cat "\$PID_FILE" 2>/dev/null || true)
            if [ -n "\$old_p" ] && kill -0 "\$old_p" 2>/dev/null; then
                exit 0
            fi
        fi
        rm -f "\$SOCK_FILE" 2>/dev/null || true
        dr_flag="--data-root \$dr"
        sock_flag="-H unix://\$SOCK_FILE"
        pid_flag="--pidfile \$PID_FILE"
        if command -v dockerd-entrypoint.sh >/dev/null 2>&1; then
            dockerd-entrypoint.sh dockerd \$sock_flag \$pid_flag \$dr_flag >/dev/null 2>&1 &
        elif command -v dockerd >/dev/null 2>&1; then
            dockerd \$sock_flag \$pid_flag \$dr_flag >/dev/null 2>&1 &
        else
            echo "[DRILL ERROR] 未找到 dockerd 可执行程序！" >&2
            exit 1
        fi
        n=0
        while [ \$n -lt 30 ]; do
            if [ -S "\$SOCK_FILE" ] && docker info >/dev/null 2>&1; then
                break
            fi
            n=\$((n + 1))
            sleep 1
        done
        if [ \$n -ge 30 ]; then
            echo "[DRILL ERROR] 专属 dockerd 守护进程启动超时！" >&2
            exit 1
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
mkdir -p "$DRILL_SYS_ROOT/etc/init.d" "$DRILL_SYS_ROOT/etc/config" "$DRILL_SYS_ROOT/etc/docker"
cp "$DRILL_SYS_ROOT/etc_init_dockerd" "$DRILL_SYS_ROOT/etc/init.d/dockerd"
chmod +x "$DRILL_SYS_ROOT/etc/init.d/dockerd"
echo "1" > "$DRILL_SYS_ROOT/dockerd_enabled"

cat << EOF > "$DRILL_BIN/uci"
#!/bin/sh
CONFIG_DIR="$DRILL_SYS_ROOT/etc/config"
while [ \$# -gt 0 ]; do
    case "\$1" in
        -c)
            shift
            [ \$# -gt 0 ] && CONFIG_DIR="\$1"
            shift || true
            ;;
        -q)
            shift || true
            ;;
        *)
            break
            ;;
    esac
done

cmd="\${1:-}"
shift || true
CONFIG_FILE="\$CONFIG_DIR/dockerd.data_root"

case "\$cmd" in
    get)
        case "\${1:-}" in
            dockerd.globals.data_root)
                cat "\$CONFIG_FILE" 2>/dev/null || echo ""
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    set)
        key=\$(echo "\${1:-}" | cut -d= -f1)
        val=\$(echo "\${1:-}" | cut -d= -f2-)
        if [ "\$key" = "dockerd.globals.data_root" ]; then
            mkdir -p "\$(dirname "\$CONFIG_FILE")"
            echo "\$val" > "\$CONFIG_FILE"
        fi
        exit 0
        ;;
    commit)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$DRILL_BIN/uci"
ORIG_PATH="$PATH"
PATH="$DRILL_BIN:$PATH"
export PATH

# 动态独立资源名称（避免名称碰撞）
CONTAINER_NAME="drill_standalone_$$"
SNAPSHOT_IMAGE="backup-snapshot-${CONTAINER_NAME}:latest"

cleanup() {
    log "正在清理真实演练容器与专属守护进程..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rmi -f "$SNAPSHOT_IMAGE" 2>/dev/null || true
    if [ -f "$DRILL_SYS_ROOT/etc/init.d/dockerd" ]; then
        "$DRILL_SYS_ROOT/etc/init.d/dockerd" stop 2>/dev/null || true
    fi
    rm -rf "$DRILL_ROOT" 2>/dev/null || true
    cleanup_drill_storage
    PATH="$ORIG_PATH"
}
trap cleanup EXIT INT TERM

log "=== 开始 AX6600 Docker 真实环境端到端隔离演练 ==="
log "演练临时根目录: $DRILL_ROOT"

# 启动专属 dockerd 实例
"$DRILL_SYS_ROOT/etc/init.d/dockerd" start

# 严格校验专属端点
if [ -z "${DOCKER_HOST:-}" ] || [ "$DOCKER_HOST" != "unix://$DRILL_SOCK" ]; then
    log_err "DOCKER_HOST 未固定为专属端点: unix://$DRILL_SOCK"
    exit 1
fi
if [ "$DRILL_SOCK" = "/var/run/docker.sock" ]; then
    log_err "安全阻断: 严禁使用系统公共套接字 /var/run/docker.sock！"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    log_err "专属 Docker 端点连接失败！"
    exit 1
fi
log "专属 Docker 守护进程与端点就绪: $DOCKER_HOST"

# 准备持久化绑定数据
echo "secret_bind_payload_v1" > "$DRILL_BIND_SRC/app_config.env"
echo "host_persistent_state_42" > "$DRILL_BIND_SRC/state.db"

# 5. 准备并启动真实独立容器
log "正在拉起演练独立容器 $CONTAINER_NAME..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

TEST_IMAGE="alpine:latest"
if ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    docker pull "$TEST_IMAGE" || true
fi

# 启动容器时执行无害长驻进程，防止恢复启动时重写覆盖测试数据
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -e DRILL_ENV_VAR="ax6600_test_val_999" \
    -v "$DRILL_BIND_SRC:/data_host" \
    "$TEST_IMAGE" sleep 3600

sleep 1

# 在容器运行时写入可写层脏数据（该数据将被 commit 保存入快照镜像）
docker exec "$CONTAINER_NAME" sh -c "echo 'flush_data_before_shutdown' > /data_runtime.txt"

# 6. 执行真实冷备 (调用 helper 备份)
log "执行 helper 备份..."
sh "$HELPER_SCRIPT" backup \
    --target-dir "$DRILL_BACKUP" \
    --sys-root "$DRILL_SYS_ROOT"

# 7. 校验备份一致性产物
log "校验备份关键产物..."
if [ ! -f "$DRILL_BACKUP/backup_manifest.txt" ] || [ ! -f "$DRILL_BACKUP/sha256sums.txt" ]; then
    log_err "备份清单缺失！"
    exit 1
fi

(cd "$DRILL_BACKUP" && sha256sum -c sha256sums.txt) || {
    log_err "备份文件哈希校验自检失败！"
    exit 1
}

if [ ! -f "$DRILL_BACKUP/standalone/recreate_${CONTAINER_NAME}.sh" ]; then
    log_err "独立容器重建脚本未生成: recreate_${CONTAINER_NAME}.sh"
    exit 1
fi

if [ ! -f "$DRILL_BACKUP/standalone/image_${CONTAINER_NAME}.tar" ]; then
    log_err "独立容器快照镜像未导出: image_${CONTAINER_NAME}.tar"
    exit 1
fi

# 8. 销毁原始容器并清空原宿主测试数据，模拟换盘或固件重置
log "销毁原始容器并清空测试数据，模拟换盘或固件重置..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
echo "corrupted_dirty_data" > "$DRILL_BIND_SRC/state.db"

# 9. 执行恢复 (调用 helper 恢复至新 DataRoot)
log "执行 helper 恢复..."
sh "$HELPER_SCRIPT" restore \
    --backup-dir "$DRILL_BACKUP" \
    --target-data-root "$DRILL_RESTORE_DATA" \
    --sys-root "$DRILL_SYS_ROOT"

# 10. 验收恢复结果
log "验收容器运行状态与数据一致性..."
# 校验 Docker 守护进程实际数据目录已准确切换至恢复目标目录
ACTUAL_DATA_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
EXPECTED_DATA_ROOT=$(cd "$DRILL_RESTORE_DATA" && pwd -P)
RESOLVED_ACTUAL=$(cd "$ACTUAL_DATA_ROOT" 2>/dev/null && pwd -P || echo "$ACTUAL_DATA_ROOT")
if [ "$RESOLVED_ACTUAL" != "$EXPECTED_DATA_ROOT" ]; then
    log_err "Docker 守护进程 DockerRootDir 未切换至预期目录！预期: $EXPECTED_DATA_ROOT, 实际: $RESOLVED_ACTUAL"
    exit 1
fi
log "DockerRootDir 验证一致: $RESOLVED_ACTUAL"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_err "独立容器 $CONTAINER_NAME 未成功恢复运行！"
    exit 1
fi

# 验证宿主持久化数据已准确覆盖还原
RESTORED_STATE=$(cat "$DRILL_BIND_SRC/state.db" 2>/dev/null || echo "")
if [ "$RESTORED_STATE" != "host_persistent_state_42" ]; then
    log_err "Bind Mount 持久化数据未正确恢复！实际值: $RESTORED_STATE"
    exit 1
fi

# 验证容器内部落盘数据（快照镜像还原）
RESTORED_INTERNAL=$(docker exec "$CONTAINER_NAME" cat /data_runtime.txt 2>/dev/null || echo "")
if ! echo "$RESTORED_INTERNAL" | grep -q "flush_data_before_shutdown"; then
    log_err "容器内部快照数据未正确还原！实际值: $RESTORED_INTERNAL"
    exit 1
fi

# 验证容器环境变量
RESTORED_ENV=$(docker exec "$CONTAINER_NAME" env 2>/dev/null | grep "^DRILL_ENV_VAR=" | cut -d= -f2- || true)
if [ "$RESTORED_ENV" != "ax6600_test_val_999" ]; then
    log_err "容器环境变量还原不匹配！实际值: $RESTORED_ENV"
    exit 1
fi

log "=== 真实 Docker 端到端隔离演练全部通过！==="
exit 0
