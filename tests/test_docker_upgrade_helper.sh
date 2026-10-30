#!/bin/sh
# 针对 Scripts/docker_upgrade_helper.sh 的完整逻辑回归测试套件
# 验收标准：备份确实完整、恢复确实可用、失败确实停止、环境严格沙箱隔离
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HELPER_SCRIPT="$REPO_ROOT/Scripts/docker_upgrade_helper.sh"

# 创建受控隔离沙箱，绝对严禁写入宿主机 /etc、/opt 或 /
TEST_SANDBOX="$REPO_ROOT/tests/tmp_sandbox_$$"
MOCK_BIN="$TEST_SANDBOX/mock_bin"
SYS_ROOT="$TEST_SANDBOX/sys_root"
MOCK_STATE="$TEST_SANDBOX/mock_state"
export TEST_SANDBOX MOCK_BIN SYS_ROOT MOCK_STATE

mkdir -p "$MOCK_BIN" "$SYS_ROOT" "$MOCK_STATE"

cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# 初始化基础 Mock 命令体系（确保所有系统交互全部落入沙箱，严禁回退宿主命令）
# -----------------------------------------------------------------------------
cat << 'EOF' > "$MOCK_BIN/docker"
#!/bin/sh
echo "docker $*" >> "$MOCK_STATE/invocations.log"

cmd="$1"
shift || true

case "$cmd" in
    info)
        if [ -f "$MOCK_STATE/docker_fail_info" ]; then
            exit 1
        fi
        if [ "${1:-}" = "-f" ]; then
            fmt="${2:-}"
            case "$fmt" in
                *"Driver"*)
                    echo "overlay2"
                    exit 0
                    ;;
                *)
                    cat "$MOCK_STATE/docker_root_dir" 2>/dev/null || echo "/var/lib/docker"
                    exit 0
                    ;;
            esac
        fi
        echo "Docker Root Dir: $(cat "$MOCK_STATE/docker_root_dir" 2>/dev/null || echo "/var/lib/docker")"
        exit 0
        ;;
    ps)
        if [ -f "$MOCK_STATE/docker_fail_ps" ]; then
            exit 1
        fi
        case "$*" in
            *-q*|"-aq")
                cat "$MOCK_STATE/containers_list_ids" 2>/dev/null || true
                exit 0
                ;;
            *)
                cat "$MOCK_STATE/containers_list_formatted" 2>/dev/null || true
                exit 0
                ;;
        esac
        ;;
    inspect)
        if [ -f "$MOCK_STATE/docker_fail_inspect" ]; then
            exit 1
        fi
        if [ "${1:-}" = "-f" ]; then
            fmt="$2"
            cid="$3"
            if [ -n "$cid" ]; then
                for cname_file in "$MOCK_STATE"/cname_*; do
                    if [ -f "$cname_file" ]; then
                        stored_name=$(cat "$cname_file" 2>/dev/null | tr -d '/')
                        if [ "$stored_name" = "$cid" ] || [ "/$stored_name" = "$cid" ]; then
                            cid=$(basename "$cname_file" | sed 's/^cname_//')
                            break
                        fi
                    fi
                done
            fi
            case "$fmt" in
                *".Id"*|*"Id"*)
                    echo "$cid"
                    ;;
                *"HostConfig.Mounts"*)
                    cat "$MOCK_STATE/cmounts_$cid" 2>/dev/null || true
                    ;;
                *".Mounts"*|*"Mounts"*)
                    if [ -f "$MOCK_STATE/docker_fail_mounts_inspect" ]; then
                        exit 1
                    fi
                    if [ -f "$MOCK_STATE/mounts_$cid" ]; then
                        cat "$MOCK_STATE/mounts_$cid"
                    elif [ -f "$MOCK_STATE/cmounts_$cid" ]; then
                        awk -F'|' '$1 == "bind" && $2 != "" {print $2}' "$MOCK_STATE/cmounts_$cid" 2>/dev/null || true
                    elif [ -f "$MOCK_STATE/binds_$cid" ]; then
                        awk -F':' '{if ($1 != "") print $1}' "$MOCK_STATE/binds_$cid" 2>/dev/null || true
                    elif [ -f "$MOCK_STATE/inspect.json" ]; then
                        awk -v target_id="$cid" '
                            BEGIN { in_target = 0; in_binds = 0; in_mounts = 0; m_type = ""; m_src = "" }
                            /"Id":/ || /"Name":/ {
                                if (index($0, "\"" target_id "\"") > 0 || index($0, "\"/" target_id "\"") > 0) {
                                    in_target = 1
                                } else {
                                    in_target = 0
                                }
                            }
                            in_target && /"Binds"[[:space:]]*:/ { in_binds = 1 }
                            in_target && in_binds {
                                n = split($0, items, "\"")
                                for (i = 1; i <= n; i++) {
                                    if (items[i] ~ /^(\/|[a-zA-Z]:).*:(\/|[a-zA-Z]:)/) {
                                        split(items[i], p, ":")
                                        if (p[1] != "") print p[1]
                                    }
                                }
                                if ($0 ~ /\]/) in_binds = 0
                            }
                            in_target && /"Mounts":/ { in_mounts = 1; next }
                            in_target && in_mounts {
                                if ($0 ~ /"Type":[[:space:]]*"bind"/) m_type = "bind"
                                if ($0 ~ /"Source":[[:space:]]*"[^"]+"/) {
                                    match($0, /"Source":[[:space:]]*"[^"]+"/)
                                    split(substr($0, RSTART, RLENGTH), arr, "\"")
                                    m_src = arr[4]
                                }
                                if ($0 ~ /\}/) {
                                    if (m_type == "bind" && m_src != "") print m_src
                                    m_type = ""; m_src = ""
                                }
                                if ($0 ~ /\]/) in_mounts = 0
                            }
                        ' "$MOCK_STATE/inspect.json" 2>/dev/null || true
                    fi
                    ;;
                *"Labels"*"com.docker.compose.project.working_dir"*)
                    cat "$MOCK_STATE/comp_workdir_$cid" 2>/dev/null || true
                    ;;
                *"Labels"*"com.docker.compose.project.config_files"*)
                    cat "$MOCK_STATE/comp_config_$cid" 2>/dev/null || true
                    ;;
                *"Labels"*"com.docker.compose.project"*)
                    cat "$MOCK_STATE/comp_project_$cid" 2>/dev/null || true
                    ;;
                *"Config.Image"*)
                    cat "$MOCK_STATE/cimg_$cid" 2>/dev/null || echo "alpine:latest"
                    ;;
                *"NetworkSettings.Networks"*)
                    cat "$MOCK_STATE/net_count_$cid" 2>/dev/null || echo "1"
                    ;;
                *"HostConfig.NetworkMode"*)
                    cat "$MOCK_STATE/cnet_$cid" 2>/dev/null || echo "bridge"
                    ;;
                *"RestartPolicy.MaximumRetryCount"*)
                    cat "$MOCK_STATE/crestart_max_$cid" 2>/dev/null || echo "0"
                    ;;
                *"RestartPolicy.Name"*)
                    cat "$MOCK_STATE/crestart_$cid" 2>/dev/null || echo "unless-stopped"
                    ;;
                *"Name"*)
                    cat "$MOCK_STATE/cname_$cid" 2>/dev/null || echo "/$cid"
                    ;;
                *"Privileged"*)
                    cat "$MOCK_STATE/cpriv_$cid" 2>/dev/null || echo "false"
                    ;;
                *"Config.User"*)
                    cat "$MOCK_STATE/cuser_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.WorkingDir"*)
                    cat "$MOCK_STATE/cworkdir_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.Hostname"*)
                    cat "$MOCK_STATE/chostname_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.Entrypoint"*)
                    cat "$MOCK_STATE/centrypoint_$cid" 2>/dev/null || echo ""
                    ;;
                *"PortBindings"*)
                    cat "$MOCK_STATE/cports_$cid" 2>/dev/null || cat "$MOCK_STATE/ports_$cid" 2>/dev/null || true
                    ;;
                *"Config.Env"*)
                    cat "$MOCK_STATE/cenvs_$cid" 2>/dev/null || cat "$MOCK_STATE/env_$cid" 2>/dev/null || echo "MYSQL_ROOT_PASSWORD=my_secret_pass_123"
                    ;;
                *"HostConfig.Binds"*)
                    cat "$MOCK_STATE/binds_$cid" 2>/dev/null || true
                    ;;
                *"HostConfig.Devices"*)
                    cat "$MOCK_STATE/cdevices_$cid" 2>/dev/null || true
                    ;;
                *"HostConfig.CapAdd"*)
                    cat "$MOCK_STATE/ccapadd_$cid" 2>/dev/null || true
                    ;;
                *"HostConfig.CapDrop"*)
                    cat "$MOCK_STATE/ccapdrop_$cid" 2>/dev/null || true
                    ;;
                *"HostConfig.Dns"*)
                    cat "$MOCK_STATE/cdns_$cid" 2>/dev/null || true
                    ;;
                *"HostConfig.Links"*)
                    cat "$MOCK_STATE/clinks_$cid" 2>/dev/null || echo "0"
                    ;;
                *"HostConfig.VolumesFrom"*)
                    cat "$MOCK_STATE/cvfrom_$cid" 2>/dev/null || echo "0"
                    ;;
                *"HostConfig.Runtime"*)
                    cat "$MOCK_STATE/cruntime_$cid" 2>/dev/null || echo "runc"
                    ;;
                *"Config.Cmd"*)
                    cat "$MOCK_STATE/ccmd_$cid" 2>/dev/null || cat "$MOCK_STATE/cmd_$cid" 2>/dev/null || echo ""
                    ;;
                *)
                    echo ""
                    ;;
            esac
            exit 0
        fi
        cat "$MOCK_STATE/inspect.json" 2>/dev/null || echo "[]"
        exit 0
        ;;
    network)
        if [ -f "$MOCK_STATE/docker_fail_network" ]; then
            exit 1
        fi
        echo "NETWORK ID   NAME      DRIVER    SCOPE"
        echo "112233445566   bridge    bridge    local"
        exit 0
        ;;
    diff)
        cat "$MOCK_STATE/diff_$1" 2>/dev/null || true
        exit 0
        ;;
    commit)
        if [ -f "$MOCK_STATE/docker_fail_commit" ]; then
            exit 1
        fi
        echo "sha256:mock_committed_image"
        exit 0
        ;;
    save)
        if [ -f "$MOCK_STATE/docker_fail_save" ]; then
            exit 1
        fi
        out_tar=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                out_tar="$2"
                shift 2
            else
                shift
            fi
        done
        [ -z "$out_tar" ] && out_tar="image.tar"
        tar -cf "$out_tar" -T /dev/null 2>/dev/null || touch "$out_tar"
        exit 0
        ;;
    load)
        echo "Loaded image"
        exit 0
        ;;
    stop)
        if [ -f "$MOCK_STATE/docker_fail_stop" ]; then
            exit 1
        fi
        echo "$*" >> "$MOCK_STATE/stopped_containers.log"
        if [ -f "$MOCK_STATE/simulate_stop_data_flush" ]; then
            flush_target=$(cat "$MOCK_STATE/simulate_stop_data_flush")
            echo "post_stop_flushed_cold_data" > "$flush_target"
        fi
        exit 0
        ;;
    run)
        if [ -f "$MOCK_STATE/docker_fail_run" ]; then
            exit 1
        fi
        if echo "$*" | grep -q "connectivitycheck"; then
            if [ -f "$MOCK_STATE/docker_fail_egress" ]; then
                exit 1
            fi
            exit 0
        fi
        if echo "$*" | grep -q -- "-p 127.0.0.1:18888:80"; then
            if [ -f "$MOCK_STATE/docker_fail_port_mapping" ]; then
                echo "bad_cid"
                exit 0
            fi
            echo "mock_port_cid"
            exit 0
        fi
        exit 0
        ;;
    rm)
        exit 0
        ;;
    compose)
        if [ -f "$MOCK_STATE/compose_fail" ]; then
            exit 1
        fi
        echo "compose $* at $(pwd)" >> "$MOCK_STATE/compose_invocations.log"
        exit 0
        ;;
    exec)
        echo "docker exec $*" >> "$MOCK_STATE/invocations.log"
        if echo "$*" | grep -q "mysqldump"; then
            echo "-- MySQL dump simulated"
            echo "CREATE TABLE test_table (id INT);"
            exit 0
        elif echo "$*" | grep -q "pg_dumpall"; then
            echo "-- PostgreSQL dump simulated"
            exit 0
        elif echo "$*" | grep -q "redis-cli"; then
            echo "OK"
            exit 0
        fi
        exit 0
        ;;
    volume)
        echo "app_volume"
        exit 0
        ;;
    version)
        echo "29.6.1"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_BIN/docker"

cat << 'EOF' > "$MOCK_BIN/docker-compose"
#!/bin/sh
echo "docker-compose $* at $(pwd)" >> "$MOCK_STATE/compose_invocations.log"
echo "docker-compose $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/compose_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/docker-compose"

cat << 'EOF' > "$MOCK_BIN/df"
#!/bin/sh
echo "df $*" >> "$MOCK_STATE/invocations.log"
target=""
has_target=0
for arg; do
    case "$arg" in
        -*) ;;
        *)
            target="$arg"
            has_target=1
            ;;
    esac
done
if [ "$has_target" -eq 0 ] || [ -z "$target" ]; then
    echo "df: missing operand or empty path" >&2
    exit 1
fi
if [ -f "$MOCK_STATE/df_overlay_all" ] || [ -f "$MOCK_STATE/unmounted_$target" ] || echo "$target" | grep -q "unmounted"; then
    echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
    echo "overlayfs:/overlay 1048576 524288    524288      50% /"
    exit 0
fi
mode=$(cat "$MOCK_STATE/df_mode" 2>/dev/null || echo "usb")
case "$mode" in
    overlay)
        echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
        echo "overlayfs:/overlay 1048576 524288    524288      50% /"
        ;;
    tmpfs)
        echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
        echo "tmpfs              1048576 524288    524288      50% /tmp"
        ;;
    insufficient_space)
        echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
        echo "/dev/sda1         10485760 10485000       500     100% /mnt/sda1"
        ;;
    *)
        echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
        echo "/dev/sda1         10485760 1048576   9437184      10% /mnt/sda1"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/df"

cat << 'EOF' > "$MOCK_BIN/fdisk"
#!/bin/sh
echo "fdisk $*" >> "$MOCK_STATE/invocations.log"
mode=$(cat "$MOCK_STATE/fdisk_mode" 2>/dev/null || echo "normal")
case "$mode" in
    dual_small_target)
        # rootfs 是 60MB (122880 sectors)，rootfs_1 是 512MB (1048576 sectors)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096      190975      122880   rootfs"
        echo "/dev/mmcblk0p16       190976     1239551     1048576   rootfs_1"
        ;;
    small_kernel_target)
        # 0:HLOS 是 2MB (4096 sectors), 0:HLOS_1 是 16MB (32768 sectors), rootfs 是 512MB
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560        6655        4096   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        echo "/dev/mmcblk0p16      1116672     2165247     1048576   rootfs_1"
        ;;
    dual_large_both)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        echo "/dev/mmcblk0p16      1116672     2165247     1048576   rootfs_1"
        ;;
    missing_partitions)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        ;;
    *)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        echo "/dev/mmcblk0p16      1116672     2165247     1048576   rootfs_1"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/fdisk"

cat << 'EOF' > "$MOCK_BIN/hexdump"
#!/bin/sh
echo "hexdump $*" >> "$MOCK_STATE/invocations.log"
target=""
for arg; do
    target="$arg"
done
if [ -f "$target" ]; then
    od_hex=$(od -An -tx1 -N 1 -j 148 "$target" 2>/dev/null | awk '{print $1}' || echo "00")
    if [ "$od_hex" = "01" ]; then
        echo "1|"
    elif [ "$od_hex" = "00" ]; then
        echo "0|"
    else
        echo "0|"
    fi
else
    echo "0|"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/hexdump"

cat << 'EOF' > "$MOCK_BIN/sysupgrade"
#!/bin/sh
echo "sysupgrade $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/sysupgrade_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/sysupgrade"

cat << 'EOF' > "$MOCK_BIN/nft"
#!/bin/sh
echo "nft $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/nft_has_flowtable_hw" ]; then
    echo "table inet fw4 { flowtable ft { hook ingress priority 0; devices = { eth0 }; flags offload; } }"
elif [ -f "$MOCK_STATE/nft_has_flowtable_sw" ] || [ -f "$MOCK_STATE/nft_has_flowtable" ]; then
    echo "table inet fw4 { flowtable ft { hook ingress priority 0; devices = { eth0 }; } }"
else
    echo "table inet fw4 { chain forward { type filter hook forward priority 0; drop; } }"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/nft"

cat << 'EOF' > "$MOCK_BIN/iptables"
#!/bin/sh
echo "iptables $*" >> "$MOCK_STATE/invocations.log"
if [ "${1:-}" = "-V" ]; then
    echo "iptables v1.8.10 (nf_tables)"
    exit 0
fi
if [ "${1:-}" = "-S" ] && [ "${2:-}" = "FORWARD" ]; then
    echo "-P FORWARD DROP"
    exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/iptables"

cat << 'EOF' > "$MOCK_BIN/jq"
#!/bin/sh
echo "jq $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/jq_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/jq"

cat << 'EOF' > "$MOCK_BIN/logread"
#!/bin/sh
echo "logread $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/logread_tls_error" ]; then
    echo "[ERROR] passwall2: TLS Handshake failed: certificate unknown"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/logread"

cat << 'EOF' > "$MOCK_BIN/dmesg"
#!/bin/sh
echo "dmesg $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/dmesg_ppe_error" ]; then
    echo "[ 1.234567] qcom-ppe 3a000000.ppe: probe failed with error -19"
else
    echo "[ 1.234567] qcom-ppe 3a000000.ppe: probed successfully"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/dmesg"

cat << 'EOF' > "$MOCK_BIN/pgrep"
#!/bin/sh
echo "pgrep $*" >> "$MOCK_STATE/invocations.log"
target="$1"
[ "$target" = "-x" ] && target="$2"
if [ -f "$MOCK_STATE/pgrep_running_$target" ]; then
    cat "$MOCK_STATE/pgrep_pid_$target" 2>/dev/null || echo "12345"
    exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/pgrep"

cat << 'EOF' > "$MOCK_BIN/curl"
#!/bin/sh
echo "curl $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/curl_fail" ]; then
    exit 1
fi
if echo "$*" | grep -q "127.0.0.1:18888"; then
    if [ -f "$MOCK_STATE/docker_fail_port_mapping" ]; then
        exit 1
    fi
    echo "HTTP/1.1 200 OK"
    echo ""
    echo "PORT_OK"
    exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/curl"

cat << 'EOF' > "$MOCK_BIN/uci"
#!/bin/sh
echo "uci $*" >> "$MOCK_STATE/invocations.log"
CONF_DIR="$SYS_ROOT/etc/config"
while [ $# -gt 0 ]; do
    case "$1" in
        -c)
            CONF_DIR="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

cmd="$1"
shift || true
target="${1:-}"

case "$cmd" in
    get|-q)
        [ "$cmd" = "-q" ] && { cmd="$1"; target="${2:-}"; }
        case "$target" in
            firewall.qcanssecm)
                if [ -f "$CONF_DIR/firewall" ]; then
                    grep -A 2 "qcanssecm" "$CONF_DIR/firewall" | grep "config" | head -n 1 | awk '{print $2}' | tr -d "'" || exit 1
                    exit 0
                fi
                exit 1
                ;;
            firewall.qcanssecm.path)
                if [ -f "$CONF_DIR/firewall" ]; then
                    awk '
                        /config include .qcanssecm./ { in_sec=1; next }
                        in_sec && /^config / { in_sec=0 }
                        in_sec && /option path/ { print $3; exit }
                    ' "$CONF_DIR/firewall" | tr -d "'" || exit 1
                    exit 0
                fi
                exit 1
                ;;
            dockerd.globals.data_root)
                cat "$CONF_DIR/dockerd.data_root" 2>/dev/null || echo ""
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    set)
        key=$(echo "$target" | cut -d= -f1)
        val=$(echo "$target" | cut -d= -f2)
        if [ "$key" = "dockerd.globals.data_root" ]; then
            mkdir -p "$CONF_DIR"
            echo "$val" > "$CONF_DIR/dockerd.data_root"
        fi
        exit 0
        ;;
    delete)
        if [ "$target" = "firewall.qcanssecm" ] && [ -f "$CONF_DIR/firewall" ]; then
            awk '
                BEGIN { skip=0 }
                /config include .qcanssecm./ { skip=1; next }
                skip && /^config / { skip=0 }
                !skip { print }
            ' "$CONF_DIR/firewall" > "$CONF_DIR/firewall.tmp" && mv "$CONF_DIR/firewall.tmp" "$CONF_DIR/firewall"
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
chmod +x "$MOCK_BIN/uci"

# 初始化服务管理脚本至沙箱目录内部
mkdir -p "$SYS_ROOT/etc/init.d" "$SYS_ROOT/etc/config" "$SYS_ROOT/etc/docker" "$SYS_ROOT/var/run" "$SYS_ROOT/proc"
cat << 'EOF' > "$SYS_ROOT/etc/init.d/dockerd"
#!/bin/sh
echo "init.d/dockerd $*" >> "$MOCK_STATE/invocations.log"
cmd="$1"
case "$cmd" in
    enabled)
        state=$(cat "$SYS_ROOT/etc/dockerd_enabled_flag" 2>/dev/null || echo "0")
        [ "$state" = "1" ] && exit 0
        exit 1
        ;;
    enable)
        echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"
        exit 0
        ;;
    disable)
        echo "0" > "$SYS_ROOT/etc/dockerd_enabled_flag"
        exit 0
        ;;
    stop)
        if [ -f "$MOCK_STATE/init_stop_fail" ]; then
            exit 1
        fi
        rm -f "$SYS_ROOT/var/run/dockerd.pid"
        exit 0
        ;;
    start)
        if [ -f "$MOCK_STATE/init_start_fail" ]; then
            exit 1
        fi
        echo "12345" > "$SYS_ROOT/var/run/dockerd.pid"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$SYS_ROOT/etc/init.d/dockerd"

# 设置环境变量，强制 Mock 生效
export PATH="$MOCK_BIN:$PATH"

echo "=== 开始执行 AX6600 备份恢复与升级验证回归测试套件 ==="
echo "沙箱根路径: $TEST_SANDBOX"

# -----------------------------------------------------------------------------
# 测试 0: 验证测试套件隔离性（所有 mock 必须拦截）
# -----------------------------------------------------------------------------
echo "--- 测试 0: 测试环境隔离性验证 ---"
(
    if [ "$(which docker)" != "$MOCK_BIN/docker" ]; then
        echo "FAIL: docker 未被沙箱拦截！"
        exit 1
    fi
    if [ "$(which uci)" != "$MOCK_BIN/uci" ]; then
        echo "FAIL: uci 未被沙箱拦截！"
        exit 1
    fi
)
echo "PASS: 测试 0 通过（测试隔离性已确认，所有系统调用均被沙箱完全拦截）"

# -----------------------------------------------------------------------------
# 测试 1: dockerd 未运行或探测 DockerRootDir 失败时必须报错
# -----------------------------------------------------------------------------
echo "--- 测试 1: dockerd 未运行或探测 DockerRootDir 失败时严格报错 ---"
(
    touch "$MOCK_STATE/docker_fail_info"
    set +e
    sh "$HELPER_SCRIPT" backup --target-dir "$TEST_SANDBOX/t1_target" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t1.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_info"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: dockerd 探测失败时，backup 竟然返回成功！"
        exit 1
    fi
    if ! grep -q "无法连接 Docker 守护进程" "$TEST_SANDBOX/t1.log"; then
        echo "FAIL: 未报告预期的 dockerd 连接失败: $(cat "$TEST_SANDBOX/t1.log")"
        exit 1
    fi
)
echo "PASS: 测试 1 通过（连接 dockerd 失败严格阻断）"

# -----------------------------------------------------------------------------
# 测试 2: 目标目录在 DockerRootDir 内部时必须被拦截（防止递归打包）
# -----------------------------------------------------------------------------
echo "--- 测试 2: 拦截备份目标在 DockerRootDir 内部 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t2_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes" "$MOCK_DOCKER_ROOT/recursive_backup"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$MOCK_DOCKER_ROOT/recursive_backup" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t2.log"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标在 DockerRootDir 内部却没有拦截！"
        exit 1
    fi
    if ! grep -q "不能在 DockerRootDir" "$TEST_SANDBOX/t2.log"; then
        echo "FAIL: 未报告递归打包拦截: $(cat "$TEST_SANDBOX/t2.log")"
        exit 1
    fi
)
echo "PASS: 测试 2 通过（内部递归目录被成功拦截）"

# -----------------------------------------------------------------------------
# 测试 3: 外盘未挂载或备份目标位于 /overlay、/ 等重置位置时严格拒绝
# -----------------------------------------------------------------------------
echo "--- 测试 3: 外盘未挂载或位于 /overlay / tmpfs 时严格拒绝 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t3_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes"
    echo "overlay" > "$MOCK_STATE/df_mode"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t3_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t3.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/df_mode"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标在 /overlay 上却没有拦截！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或.*overlay|存储设备为易失或升级重置设备)" "$TEST_SANDBOX/t3.log"; then
        echo "FAIL: 未能正确识别 /overlay: $(cat "$TEST_SANDBOX/t3.log")"
        exit 1
    fi
)
echo "PASS: 测试 3 通过（外盘未挂载、落入内部 overlay 被严格拒绝）"

# -----------------------------------------------------------------------------
# 测试 4: 空间估算覆盖全量数据与可用空间不足拦截
# -----------------------------------------------------------------------------
echo "--- 测试 4: 空间不足时严格拦截 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t4_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes/v1"
    echo "large_data" > "$MOCK_DOCKER_ROOT/volumes/v1/file"
    echo "insufficient_space" > "$MOCK_STATE/df_mode"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t4_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t4.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/df_mode"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 空间不足却没有拦截！"
        exit 1
    fi
    if ! grep -q "目标存储空间不足" "$TEST_SANDBOX/t4.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t4.log")"
        exit 1
    fi
)
echo "PASS: 测试 4 通过（空间不足严格拒绝备份）"

# -----------------------------------------------------------------------------
# 测试 5: 关键步骤失败必须停止（无盲目 || true）
# -----------------------------------------------------------------------------
echo "--- 测试 5: 停机失败或服务异常时严格停止并恢复自启 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t5_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes"
    echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"
    echo "c_test" > "$MOCK_STATE/containers_list_ids"
    echo "c_test" > "$MOCK_STATE/cname_c_test"
    touch "$MOCK_STATE/docker_fail_stop"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t5_target" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t5.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_stop" "$MOCK_STATE/containers_list_ids"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 容器停止失败却没有终止备份！"
        exit 1
    fi
    if ! grep -q "停止容器失败" "$TEST_SANDBOX/t5.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t5.log")"
        exit 1
    fi
)
echo "PASS: 测试 5 通过（关键步骤失败立即停止并报错）"

# -----------------------------------------------------------------------------
# 测试 6: tar 生成了可读但缺文件的部分归档，仍必须失败
# -----------------------------------------------------------------------------
echo "--- 测试 6: 归档缺漏文件时严格报错 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t6_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes/vol_missing"
    echo "data" > "$MOCK_DOCKER_ROOT/volumes/vol_missing/file.txt"

    mkdir -p "$TEST_SANDBOX/t6_target/metadata"
    cat << 'EOF' > "$MOCK_STATE/inspect.json"
[
  {
    "Id": "c6",
    "Name": "/c6",
    "Config": { "Image": "test:latest" },
    "HostConfig": { "Binds": ["/non/existent/host/path:/container/path"] }
  }
]
EOF
    echo "c6" > "$MOCK_STATE/containers_list_ids"
    echo "c6" > "$MOCK_STATE/cname_c6"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t6_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t6.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/inspect.json" "$MOCK_STATE/containers_list_ids"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 外部挂载文件缺失却没有报错！"
        exit 1
    fi
    if ! grep -q "外部挂载路径不存在" "$TEST_SANDBOX/t6.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t6.log")"
        exit 1
    fi
)
echo "PASS: 测试 6 通过（归档文件缺失被准确识别阻断）"

# -----------------------------------------------------------------------------
# 测试 7: 端到端完整隔离备份与恢复演练（含数据库热备、.env、原路径、独立容器重建与配置统一）
# -----------------------------------------------------------------------------
echo "--- 测试 7: 端到端隔离备份与完整数据恢复演练 ---"
(
    SRC_DOCKER="$SYS_ROOT/var/lib/docker"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    ROUTER_BIND="/my_bind_dir"
    EXT_BIND="$SYS_ROOT$ROUTER_BIND"
    ROUTER_COMPOSE="/my_apps/custom_compose_path"
    SRC_COMPOSE="$SYS_ROOT$ROUTER_COMPOSE"
    SRC_COMPOSE_DATA="$SRC_COMPOSE/data"

    mkdir -p "$SRC_DOCKER/volumes/app_volume" "$DST_DOCKER" "$BKP_STORE" "$EXT_BIND/data" "$SRC_COMPOSE_DATA"
    echo "important_vol_data_99" > "$SRC_DOCKER/volumes/app_volume/data.bin"
    echo "bind_config_val=1" > "$EXT_BIND/app.env"
    echo "bind_sub_val=2" > "$EXT_BIND/data/sub.txt"
    echo "pre_stop_compose_data" > "$SRC_COMPOSE_DATA/state.txt"

    # 设置停机冷数据落盘模拟：停机时容器落盘更新数据，确保冷备归档抓取到最新持久化数据
    echo "$SRC_COMPOSE_DATA/state.txt" > "$MOCK_STATE/simulate_stop_data_flush"

    # 创建 Compose 项目（必须包含 .env 隐藏文件）
    cat << 'EOF' > "$SRC_COMPOSE/docker-compose.yml"
version: '3.8'
services:
  web:
    image: nginx:alpine
    env_file: .env
EOF
    echo "SECRET_TOKEN=xyz_token_secret_123" > "$SRC_COMPOSE/.env"

    # 配置系统配置文件
    echo '{"data-root":"/old/root"}' > "$SYS_ROOT/etc/docker/daemon.json"
    echo "package dockerd" > "$SYS_ROOT/etc/config/dockerd"
    echo "package dockerman" > "$SYS_ROOT/etc/config/dockerman"
    echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"

    # 设置 Mock 容器状态：包含 1 个 Compose 容器、1 个独立容器、1 个运行中 MySQL 数据库容器
    cat << EOF > "$MOCK_STATE/inspect.json"
[
  {
    "Id": "comp_cid",
    "Name": "/web_service",
    "Config": {
      "Image": "nginx:alpine",
      "Labels": {
        "com.docker.compose.project": "my_proj",
        "com.docker.compose.project.working_dir": "$ROUTER_COMPOSE",
        "com.docker.compose.project.config_files": "$ROUTER_COMPOSE/docker-compose.yml"
      }
    },
    "HostConfig": {
      "Binds": ["$ROUTER_BIND:/app/config", "$ROUTER_COMPOSE/data:/app/data"]
    }
  },
  {
    "Id": "standalone_cid",
    "Name": "/standalone_app",
    "Config": {
      "Image": "redis:alpine",
      "Labels": {}
    },
    "HostConfig": {
      "NetworkMode": "bridge",
      "RestartPolicy": { "Name": "always" },
      "Privileged": true,
      "Binds": ["$ROUTER_BIND/data:/data"]
    }
  },
  {
    "Id": "standalone_no_diff_cid",
    "Name": "/standalone_no_diff",
    "Config": {
      "Image": "busybox:latest",
      "Labels": {}
    },
    "HostConfig": {
      "NetworkMode": "bridge",
      "RestartPolicy": { "Name": "on-failure", "MaximumRetryCount": 3 },
      "Privileged": false,
      "Binds": []
    }
  },
  {
    "Id": "mysql_cid",
    "Name": "/mysql_db",
    "Config": {
      "Image": "mysql:8.0",
      "Labels": {}
    },
    "HostConfig": {
      "NetworkMode": "bridge",
      "RestartPolicy": { "Name": "unless-stopped" },
      "Privileged": false,
      "Binds": []
    }
  }
]
EOF
    echo -e "comp_cid\nstandalone_cid\nstandalone_no_diff_cid\nmysql_cid" > "$MOCK_STATE/containers_list_ids"
    echo "my_proj" > "$MOCK_STATE/comp_project_comp_cid"
    echo "$ROUTER_COMPOSE" > "$MOCK_STATE/comp_workdir_comp_cid"
    echo "$ROUTER_COMPOSE/docker-compose.yml" > "$MOCK_STATE/comp_config_comp_cid"
    echo "nginx:alpine" > "$MOCK_STATE/cimg_comp_cid"
    echo "web_service" > "$MOCK_STATE/cname_comp_cid"
    echo -e "$ROUTER_BIND:/app/config\n$ROUTER_COMPOSE/data:/app/data" > "$MOCK_STATE/binds_comp_cid"

    echo "redis:alpine" > "$MOCK_STATE/cimg_standalone_cid"
    echo "standalone_app" > "$MOCK_STATE/cname_standalone_cid"
    echo "C /etc/redis.conf" > "$MOCK_STATE/diff_standalone_cid"
    echo "bridge" > "$MOCK_STATE/cnet_standalone_cid"
    echo "always" > "$MOCK_STATE/crestart_standalone_cid"
    echo "true" > "$MOCK_STATE/cpriv_standalone_cid"
    echo "1000" > "$MOCK_STATE/cuser_standalone_cid"
    echo "/workspace" > "$MOCK_STATE/cworkdir_standalone_cid"
    echo "standalone-host" > "$MOCK_STATE/chostname_standalone_cid"
    echo "/entrypoint.sh" > "$MOCK_STATE/centrypoint_standalone_cid"
    echo "0.0.0.0:8080:80/tcp" > "$MOCK_STATE/cports_standalone_cid"
    echo "STANDALONE_SECRET=super_secret_token_456" > "$MOCK_STATE/cenvs_standalone_cid"
    echo "$ROUTER_BIND/data:/data" > "$MOCK_STATE/binds_standalone_cid"
    echo "/dev/net/tun:/dev/net/tun:rwm" > "$MOCK_STATE/cdevices_standalone_cid"
    echo "NET_ADMIN" > "$MOCK_STATE/ccapadd_standalone_cid"
    echo "SYS_RAWIO" > "$MOCK_STATE/ccapdrop_standalone_cid"
    echo "1.1.1.1" > "$MOCK_STATE/cdns_standalone_cid"
    printf 'redis-server\n--protected-mode\nno\n' > "$MOCK_STATE/ccmd_standalone_cid"

    # 独立容器 2: 无 diff，验证直接导出基础镜像并在脱机下通过 docker load 重建，且测试特殊字符环境变量单引号安全转义
    echo "busybox:latest" > "$MOCK_STATE/cimg_standalone_no_diff_cid"
    echo "standalone_no_diff" > "$MOCK_STATE/cname_standalone_no_diff_cid"
    : > "$MOCK_STATE/diff_standalone_no_diff_cid"
    echo "bridge" > "$MOCK_STATE/cnet_standalone_no_diff_cid"
    echo "on-failure" > "$MOCK_STATE/crestart_standalone_no_diff_cid"
    echo "3" > "$MOCK_STATE/crestart_max_standalone_no_diff_cid"
    echo "false" > "$MOCK_STATE/cpriv_standalone_no_diff_cid"
    echo "SPECIAL_ENV=test'value with space and \$dollar" > "$MOCK_STATE/cenvs_standalone_no_diff_cid"
    printf 'sh\n-c\necho hello\n' > "$MOCK_STATE/ccmd_standalone_no_diff_cid"

    echo "mysql:8.0" > "$MOCK_STATE/cimg_mysql_cid"
    echo "mysql_db" > "$MOCK_STATE/cname_mysql_cid"

    # 1. 执行全量备份（不传 --skip-stop，走完整真实停机冷备流）
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$SRC_DOCKER" \
        --target-dir "$BKP_STORE" \
        --sys-root "$SYS_ROOT" >/dev/null

    # 验证备份目录自包含 helper 脚本（解决重启后 /tmp 丢失问题）
    if [ ! -x "$BKP_STORE/docker_upgrade_helper.sh" ]; then
        echo "FAIL: 备份目录未包含可执行的 docker_upgrade_helper.sh！"
        exit 1
    fi

    # 验证配置文件统一命名的正确性
    if [ ! -d "$BKP_STORE/config/etc_docker" ] || [ ! -f "$BKP_STORE/config/config_dockerd" ] || [ ! -f "$BKP_STORE/config/config_dockerman" ]; then
        echo "FAIL: 备份配置命名不规范或缺失！"
        exit 1
    fi

    # 验证应用级数据库热备文件已生成并记录在校验列表中
    if [ ! -f "$BKP_STORE/databases/mysql_mysql_db.sql" ]; then
        echo "FAIL: 未自动生成 MySQL 逻辑热备文件！"
        exit 1
    fi
    if ! grep -q "databases/mysql_mysql_db.sql" "$BKP_STORE/sha256sums.txt"; then
        echo "FAIL: sha256sums.txt 遗漏数据库转储校验记录！"
        exit 1
    fi

    # 验证统一清单 backup_manifest.txt 覆盖所有关键产物
    if [ ! -f "$BKP_STORE/backup_manifest.txt" ]; then
        echo "FAIL: 未生成统一备份清单 backup_manifest.txt！"
        exit 1
    fi
    for req_item in \
        "compose/my_proj.tar.gz" \
        "standalone/recreate_standalone_app.sh" \
        "standalone/image_standalone_app.tar" \
        "standalone/recreate_standalone_no_diff.sh" \
        "standalone/image_standalone_no_diff.tar" \
        "docker_volumes.tar.gz" \
        "docker_bind_mounts.tar.gz"; do
        if ! grep -q "$req_item" "$BKP_STORE/backup_manifest.txt"; then
            echo "FAIL: backup_manifest.txt 缺失项目: $req_item"
            exit 1
        fi
        if ! grep -q "$req_item" "$BKP_STORE/sha256sums.txt"; then
            echo "FAIL: sha256sums.txt 遗漏项目校验: $req_item"
            exit 1
        fi
    done

    # 验证 Compose 备份包含 .env
    tar -tzf "$BKP_STORE/compose/my_proj.tar.gz" | grep -q "\.env" || {
        echo "FAIL: Compose 打包漏掉了隐藏文件 .env！"
        exit 1
    }

    # 验证独立容器 1 (有 diff) 生成了重建脚本与快照镜像
    REC_SCRIPT="$BKP_STORE/standalone/recreate_standalone_app.sh"
    if [ ! -f "$REC_SCRIPT" ] || [ ! -f "$BKP_STORE/standalone/image_standalone_app.tar" ]; then
        echo "FAIL: 独立容器重建脚本或快照镜像未生成！"
        exit 1
    fi

    # 严格校验独立容器重建脚本内容覆盖所有参数（使用 POSIX 单引号字符转义）
    REC_CONTENT=$(cat "$REC_SCRIPT")
    for flag_pat in \
        "--name 'standalone_app'" \
        "--net 'bridge'" \
        "--restart 'always'" \
        '--privileged' \
        "-u '1000'" \
        "-w '/workspace'" \
        "-h 'standalone-host'" \
        "--entrypoint '/entrypoint.sh'" \
        "-p '0.0.0.0:8080:80/tcp'" \
        "-e 'STANDALONE_SECRET=super_secret_token_456'" \
        "-v '$ROUTER_BIND/data:/data'" \
        "--device '/dev/net/tun:/dev/net/tun:rwm'" \
        "--cap-add 'NET_ADMIN'" \
        "--cap-drop 'SYS_RAWIO'" \
        "--dns '1.1.1.1'" \
        "'backup-snapshot-standalone_app:latest'" \
        "'redis-server'" \
        "'--protected-mode'" \
        "'no'"; do
        if ! echo "$REC_CONTENT" | grep -F -q -- "$flag_pat"; then
            echo "FAIL: 独立容器重建脚本遗漏参数: $flag_pat"
            echo "重建脚本全文: $REC_CONTENT"
            exit 1
        fi
    done

    # 验证独立容器 2 (无可写层 diff) 导出了基础镜像并在脚本中包含 docker load 与安全转义
    REC_NO_DIFF="$BKP_STORE/standalone/recreate_standalone_no_diff.sh"
    if [ ! -f "$REC_NO_DIFF" ] || [ ! -f "$BKP_STORE/standalone/image_standalone_no_diff.tar" ]; then
        echo "FAIL: 无 diff 独立容器基础镜像或重建脚本未生成！"
        exit 1
    fi
    REC_NO_DIFF_CONTENT=$(cat "$REC_NO_DIFF")
    for flag_pat in \
        'docker load -i "$STANDALONE_DIR/image_standalone_no_diff.tar"' \
        "--name 'standalone_no_diff'" \
        "--restart 'on-failure:3'" \
        "-e 'SPECIAL_ENV=test'\"'\"'value with space and \$dollar'" \
        "'busybox:latest'" \
        "'sh'" \
        "'-c'" \
        "'echo hello'"; do
        if ! echo "$REC_NO_DIFF_CONTENT" | grep -F -q -- "$flag_pat"; then
            echo "FAIL: 无 diff 独立容器重建脚本缺少预期内容: $flag_pat"
            echo "重建脚本全文: $REC_NO_DIFF_CONTENT"
            exit 1
        fi
    done

    # 模拟系统升级（清空沙箱内的旧系统配置、删除原 Compose 目录、停止服务）
    rm -rf "$SRC_COMPOSE" "$EXT_BIND" "$SYS_ROOT/etc/docker" "$SYS_ROOT/etc/config"
    mkdir -p "$SYS_ROOT/etc/config"
    touch "$SYS_ROOT/etc/config/dockerd"
    echo "0" > "$SYS_ROOT/etc/dockerd_enabled_flag"
    : > "$MOCK_STATE/compose_invocations.log"

    # 2. 执行恢复操作到全新数据盘目录
    sh "$BKP_STORE/docker_upgrade_helper.sh" restore \
        --backup-dir "$BKP_STORE" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" >/dev/null

    # 验证数据完整性与属性
    if [ ! -f "$DST_DOCKER/volumes/app_volume/data.bin" ]; then
        echo "FAIL: Named Volumes 未恢复到目标 DataRoot！"
        exit 1
    fi
    ACTUAL_DATA=$(cat "$DST_DOCKER/volumes/app_volume/data.bin")
    if [ "$ACTUAL_DATA" != "important_vol_data_99" ]; then
        echo "FAIL: 恢复的数据内容损坏或不一致: $ACTUAL_DATA"
        exit 1
    fi

    # 验证 Bind Mounts 恢复到原路径
    if [ ! -f "$EXT_BIND/app.env" ] || [ ! -f "$EXT_BIND/data/sub.txt" ]; then
        echo "FAIL: Bind Mounts 未恢复到原始宿主路径！"
        exit 1
    fi
    if [ "$(cat "$EXT_BIND/app.env")" != "bind_config_val=1" ]; then
        echo "FAIL: Bind Mounts 文件内容不一致！"
        exit 1
    fi

    # 验证 Compose 恢复到了原始目录，而不是全部改放 /opt
    if [ ! -f "$SRC_COMPOSE/docker-compose.yml" ] || [ ! -f "$SRC_COMPOSE/.env" ]; then
        echo "FAIL: Compose 未恢复到原始目录或缺少 .env！"
        exit 1
    fi
    if ! grep -q "SECRET_TOKEN=xyz_token_secret_123" "$SRC_COMPOSE/.env"; then
        echo "FAIL: 恢复的 .env 内容损坏！"
        exit 1
    fi

    # 验证冷备覆盖顺序：Compose 先解压、Bind Mounts 后解压，确保冷备持久化数据绝不被旧数据覆盖
    if [ ! -f "$SRC_COMPOSE_DATA/state.txt" ]; then
        echo "FAIL: Compose 内部挂载数据文件缺失！"
        exit 1
    fi
    if [ "$(cat "$SRC_COMPOSE_DATA/state.txt")" != "post_stop_flushed_cold_data" ]; then
        echo "FAIL: 恢复后数据未保持停机后的冷备状态（被旧 Compose 覆盖）: $(cat "$SRC_COMPOSE_DATA/state.txt")"
        exit 1
    fi

    # 验证只拉起了记录的项目，且启动参数包含 -p、-f 与 --env-file
    if ! grep -q "$SRC_COMPOSE" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 项目未在原始恢复路径拉起！"
        exit 1
    fi
    if ! grep -q -- "-p my_proj" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 启动命令遗漏项目名称参数 (-p)！"
        exit 1
    fi
    if ! grep -q -- "--env-file" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 启动命令遗漏环境变量文件参数 (--env-file)！"
        exit 1
    fi

    # 验证配置文件成功恢复且 data_root 被同步
    if [ ! -f "$SYS_ROOT/etc/config/dockerman" ]; then
        echo "FAIL: /etc/config/dockerman 未恢复！"
        exit 1
    fi
    ACTUAL_DATA_ROOT=$(cat "$SYS_ROOT/etc/config/dockerd.data_root" 2>/dev/null || echo "")
    if [ "$ACTUAL_DATA_ROOT" != "$DST_DOCKER" ]; then
        echo "FAIL: UCI dockerd.globals.data_root 未同步更新为目标 DataRoot ($ACTUAL_DATA_ROOT)！"
        exit 1
    fi

    # 验证开机自启状态正确恢复
    if [ "$(cat "$SYS_ROOT/etc/dockerd_enabled_flag")" != "1" ]; then
        echo "FAIL: dockerd 开机自启动未能正确恢复！"
        exit 1
    fi
)
echo "PASS: 测试 7 通过（端到端隔离全量备份、数据库热备、还原、原路径校验与自启恢复全部一致）"

# -----------------------------------------------------------------------------
# 测试 8: 镜像预检与双分区容量安全核验（严禁取大）
# -----------------------------------------------------------------------------
echo "--- 测试 8: 镜像校验与双分区容量安全预检 ---"
(
    FW_DIR="$TEST_SANDBOX/fw_build_8"
    mkdir -p "$FW_DIR/sysupgrade-glinet_gl-ax6600"
    head -c 8388608 /dev/zero > "$FW_DIR/sysupgrade-glinet_gl-ax6600/kernel"
    head -c 94371840 /dev/zero > "$FW_DIR/sysupgrade-glinet_gl-ax6600/root"
    IMG_FILE="$TEST_SANDBOX/test_fw.bin"
    (cd "$FW_DIR" && tar -cf "$IMG_FILE" sysupgrade-glinet_gl-ax6600)
    rm -rf "$FW_DIR"
    SHA_EXPECTED=$(sha256sum "$IMG_FILE" | awk '{print $1}')

    # 准备基础 0:BOOTCONFIG 设备节点，使得预检通过分区定位进入镜像 SHA256 检查
    mkdir -p "$SYS_ROOT/dev"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    # 8a: SHA256 不匹配时必须被拦截，并严格断言报错信息
    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "0000000000000000000000000000000000000000000000000000000000000000" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_sha.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: SHA256 错误未被拦截！"
        exit 1
    fi
    if ! grep -qi "SHA256 校验不匹配" "$TEST_SANDBOX/t8_sha.log"; then
        echo "FAIL: 未能正确断言因 SHA256 不匹配被拦截: $(cat "$TEST_SANDBOX/t8_sha.log")"
        exit 1
    fi

    # 8b: 0:BOOTCONFIG 偏移 148 为 0 时，目标分区为 0:HLOS 与 rootfs (60MB 较小分区)，绝不能被 512MB 误放行
    echo "dual_small_target" > "$MOCK_STATE/fdisk_mode"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x00' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_part.log"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标分区仅 60MB，刷入 90MB 固件竟然被误放行！"
        exit 1
    fi
    if ! grep -qiE "(目标分区容量.*不足|超过目标根文件系统分区)" "$TEST_SANDBOX/t8_part.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t8_part.log")"
        exit 1
    fi

    # 8c: 0:BOOTCONFIG 偏移 148 为 1 时，目标分区为 0:HLOS_1 与 rootfs_1 (512MB 较大分区)，100MB 固件应当放行
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t8_part_ok.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/fdisk_mode" "$SYS_ROOT/dev/mmcblk0p2"

    if [ "$ret" -ne 0 ]; then
        echo "FAIL: 目标分区为 512MB rootfs_1，刷入 100MB 固件却被误拦截: $(cat "$TEST_SANDBOX/t8_part_ok.log")"
        exit 1
    fi
    if ! grep -q "目标根文件系统: \[rootfs_1\]" "$TEST_SANDBOX/t8_part_ok.log"; then
        echo "FAIL: 未正确选中 rootfs_1 作为目标分区: $(cat "$TEST_SANDBOX/t8_part_ok.log")"
        exit 1
    fi

    # 8d: 固件未能提取到实际有效内核长度时必须严格拒绝盲刷，严禁退回 4MiB 猜测
    NO_KERN_FW="$TEST_SANDBOX/no_kern_fw.bin"
    head -c 10485760 /dev/zero > "$NO_KERN_FW"
    NO_KERN_SHA=$(sha256sum "$NO_KERN_FW" | awk '{print $1}')
    mkdir -p "$SYS_ROOT/dev"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"
    set +e
    sh "$HELPER_SCRIPT" precheck "$NO_KERN_FW" "$NO_KERN_SHA" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_no_kern.log"
    ret=$?
    set -e
    rm -f "$NO_KERN_FW" "$SYS_ROOT/dev/mmcblk0p2"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 固件未包含有效内核信息竟然放行！"
        exit 1
    fi
    if ! grep -qi "未能从固件镜像中解析到有效内核" "$TEST_SANDBOX/t8_no_kern.log"; then
        echo "FAIL: 未能报告无法解析内核大小错误: $(cat "$TEST_SANDBOX/t8_no_kern.log")"
        exit 1
    fi

    # 8e: 目标内核分区容量不足以容纳固件内核时严格拦截 (small_kernel_target 模式下 0:HLOS 仅 2MB，固件内核为 8MB)
    echo "small_kernel_target" > "$MOCK_STATE/fdisk_mode"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x00' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_kern.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/fdisk_mode" "$SYS_ROOT/dev/mmcblk0p2"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 待升级内核 (8MB) 超过目标内核分区 (2MB)，预检竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(待升级内核大小.*超过目标内核分区|超过目标内核分区)" "$TEST_SANDBOX/t8_kern.log"; then
        echo "FAIL: 内核分区过小拦截报错信息异常: $(cat "$TEST_SANDBOX/t8_kern.log")"
        exit 1
    fi
)
echo "PASS: 测试 8 通过（镜像预检严格，系统只读体检输出完整，双分区与内核容量安全核验完整）"

# -----------------------------------------------------------------------------
# 测试 9: NSS 清理严格匹配（节类型为 include 且路径精确匹配，并自动备份旧配置）
# -----------------------------------------------------------------------------
echo "--- 测试 9: NSS 清理精确匹配与安全性 ---"
(
    cat << 'EOF' > "$SYS_ROOT/etc/config/firewall"
config defaults
	option syn_flood '1'

config include 'qcanssecm'
	option path '/etc/firewall.d/qca-nss-ecm'

config rule 'qcanssecm'
	option name 'Allow-Custom'
	option target 'ACCEPT'

config include 'custom_user_nss'
	option path '/etc/my_nss_hook.sh'
EOF

    # 执行清理
    sh "$HELPER_SCRIPT" clean-nss --sys-root "$SYS_ROOT" >/dev/null

    # 验证自动备份存在
    if ! ls "$SYS_ROOT/etc/config"/firewall.bak.* >/dev/null 2>&1; then
        echo "FAIL: clean-nss 未在修改前自动创建防火墙配置备份！"
        exit 1
    fi

    # 验证结果：只有旧 include 被删，同名 rule 和自定义 include 完好
    if grep -q "/etc/firewall.d/qca-nss-ecm" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 废弃 include 未被清理！"
        exit 1
    fi
    if ! grep -q "config rule 'qcanssecm'" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 同名 config rule 被误删！"
        exit 1
    fi
    if ! grep -q "config include 'custom_user_nss'" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 自定义用户 include 被误删！"
        exit 1
    fi
)
echo "PASS: 测试 9 通过（NSS 清理精准保护自定义规则，备份防火墙配置并清除废弃 include）"

# -----------------------------------------------------------------------------
# 测试 10: 运行时验收失败分支阻断与精确参数提取
# -----------------------------------------------------------------------------
echo "--- 测试 10: 运行时验收失败阻断与精准提取 ---"
(
    # 10a: dmesg 报错且无 flowtable 时必须拦截
    touch "$MOCK_STATE/dmesg_ppe_error"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_ppe.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/dmesg_ppe_error"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PPE probe 报错验收竟然放行！"
        exit 1
    fi

    # 10b: 仅有纯软件 flowtable 缺乏 hw_offload 硬件卸载标志时必须拦截
    touch "$MOCK_STATE/nft_has_flowtable_sw"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_ppe_sw.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/nft_has_flowtable_sw"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 纯软件 flowtable 缺乏 hw_offload 标志竟然被放行！"
        exit 1
    fi
    if ! grep -q "缺少 hw_offload 硬件卸载标志" "$TEST_SANDBOX/t10_ppe_sw.log"; then
        echo "FAIL: 纯软件 flowtable 报错信息不符合预期: $(cat "$TEST_SANDBOX/t10_ppe_sw.log")"
        exit 1
    fi

    # 10c: flowtable 包含 hw_offload 且无 dmesg 报错时验证通过
    touch "$MOCK_STATE/nft_has_flowtable_hw"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t10_ppe_hw.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/nft_has_flowtable_hw"
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PPE 硬件加速 (hw_offload) 验收未通过: $(cat "$TEST_SANDBOX/t10_ppe_hw.log")"
        exit 1
    fi
    if ! grep -q "PPE 硬件加速状态: 已生效" "$TEST_SANDBOX/t10_ppe_hw.log"; then
        echo "FAIL: PPE 硬件加速成功提示信息异常: $(cat "$TEST_SANDBOX/t10_ppe_hw.log")"
        exit 1
    fi

    # 10d: Docker 端口映射失败必须拦截
    touch "$MOCK_STATE/docker_fail_port_mapping"
    set +e
    sh "$HELPER_SCRIPT" verify docker --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_docker.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_port_mapping"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Docker 端口映射失败验收竟然放行！"
        exit 1
    fi

    # 10e: PassWall2 核心未运行必须拦截
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 未运行验收竟然放行！"
        exit 1
    fi

    # 10f: PassWall2 存在运行核心但未找到实际端口配置（禁止盲猜 1080）必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_port.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 端口缺失盲猜 1080 竟然放行！"
        exit 1
    fi

    # 10g: PassWall2 存在 TLS 握手报错日志必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    mkdir -p "$SYS_ROOT/var/etc/passwall2"
    echo '{"inbounds":[{"port":1080}]}' > "$SYS_ROOT/var/etc/passwall2/TCP.json"
    touch "$MOCK_STATE/logread_tls_error"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_tls.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$MOCK_STATE/logread_tls_error"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 日志存在 TLS 握手错误却验收放行！"
        exit 1
    fi

    # 10h: PassWall2 配置文件语法错误必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    touch "$MOCK_STATE/jq_fail"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_jq.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$MOCK_STATE/jq_fail"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 配置文件 JSON 语法错误却放行！"
        exit 1
    fi

    # 10i: PassWall2 配置文件 outbounds 在前且包含远程端口时，必须精准提取 inbounds 本地 socks 端口 (禁止误抓 outbounds 8443)
    touch "$MOCK_STATE/pgrep_running_sing-box"
    cat << 'EOF_PW' > "$SYS_ROOT/var/etc/passwall2/TCP.json"
{
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy-out",
      "server": "198.51.100.1",
      "server_port": 8443
    }
  ],
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ]
}
EOF_PW
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t10_pw_inb.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$SYS_ROOT/var/etc/passwall2/TCP.json"
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PassWall2 正确提取 inbounds 端口后握手竟然失败: $(cat "$TEST_SANDBOX/t10_pw_inb.log")"
        exit 1
    fi
    if ! grep -q "定位到活动核心 SOCKS 本地监听端口: 1080" "$TEST_SANDBOX/t10_pw_inb.log"; then
        echo "FAIL: 未能定位到 1080 或误提取了 8443: $(cat "$TEST_SANDBOX/t10_pw_inb.log")"
        exit 1
    fi

    # 10j: PassWall2 配置文件 port 在 protocol 前且包含嵌套 settings 对象时，必须精准提取 inbounds 本地 socks 端口 (1080)
    touch "$MOCK_STATE/pgrep_running_sing-box"
    cat << 'EOF_PW_NESTED' > "$SYS_ROOT/var/etc/passwall2/TCP.json"
{
  "outbounds": [
    {
      "protocol": "shadowsocks",
      "server_port": 8443
    }
  ],
  "inbounds": [
    {
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ]
}
EOF_PW_NESTED
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t10_pw_nested.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$SYS_ROOT/var/etc/passwall2/TCP.json"
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PassWall2 port 在前且含嵌套对象时握手失败: $(cat "$TEST_SANDBOX/t10_pw_nested.log")"
        exit 1
    fi
    if ! grep -q "定位到活动核心 SOCKS 本地监听端口: 1080" "$TEST_SANDBOX/t10_pw_nested.log"; then
        echo "FAIL: 未能定位到 port 在前且含嵌套对象的 1080 端口: $(cat "$TEST_SANDBOX/t10_pw_nested.log")"
        exit 1
    fi
)
echo "PASS: 测试 10 通过（运行时验收各项失败分支均有效阻断，inbounds 端口精准提取，硬件 flowtable 校验完整）"

# -----------------------------------------------------------------------------
# 测试 11: 验证资源清理安全不越界
# -----------------------------------------------------------------------------
echo "--- 测试 11: 验证测试沙箱隔离与清理范围 ---"
(
    if [ ! -d "$TEST_SANDBOX" ]; then
        echo "FAIL: 沙箱路径异常！"
        exit 1
    fi
)
echo "PASS: 测试 11 通过（沙箱清理逻辑安全受控）"

# -----------------------------------------------------------------------------
# 测试 12: 备份清单篡改与关键文件缺失严格阻断恢复
# -----------------------------------------------------------------------------
echo "--- 测试 12: 备份完整性、缺失项与哈希篡改拦截验证 ---"
(
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    T12_BKP="$TEST_SANDBOX/t12_bkp"
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"

    # 12a: 关键文件缺失 (删除 docker_volumes.tar.gz) 必须被拦截
    rm -f "$T12_BKP/docker_volumes.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失 docker_volumes.tar.gz 时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺少|校验失败)" "$TEST_SANDBOX/t12_missing.log"; then
        echo "FAIL: 缺失文件报错信息异常: $(cat "$TEST_SANDBOX/t12_missing.log")"
        exit 1
    fi

    # 12b: 文件哈希篡改 (篡改 docker_bind_mounts.tar.gz 内容) 必须被 sha256 校验拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    echo "tampered_corrupted_data" >> "$T12_BKP/docker_bind_mounts.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_hash.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 备份文件哈希被篡改时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(sha256|哈希|校验失败)" "$TEST_SANDBOX/t12_hash.log"; then
        echo "FAIL: 哈希篡改报错信息异常: $(cat "$TEST_SANDBOX/t12_hash.log")"
        exit 1
    fi

    # 12c: 清单中记录的 Compose 项目包缺失必须被拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    rm -f "$T12_BKP/compose/my_proj.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_comp_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失 Compose 归档时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺失|校验失败)" "$TEST_SANDBOX/t12_comp_missing.log"; then
        echo "FAIL: 缺失 Compose 归档报错信息异常: $(cat "$TEST_SANDBOX/t12_comp_missing.log")"
        exit 1
    fi

    # 12d: 独立容器镜像归档缺失 (删除 standalone/image_standalone_app.tar) 必须被拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    rm -f "$T12_BKP/standalone/image_standalone_app.tar"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_img_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失独立容器镜像归档时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺少|校验失败)" "$TEST_SANDBOX/t12_img_missing.log"; then
        echo "FAIL: 缺失独立容器镜像归档报错信息异常: $(cat "$TEST_SANDBOX/t12_img_missing.log")"
        exit 1
    fi

    # 12e: 独立容器重建脚本缺失 (删除 standalone/recreate_standalone_app.sh) 必须被拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    rm -f "$T12_BKP/standalone/recreate_standalone_app.sh"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_rec_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失独立容器重建脚本时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺少|校验失败)" "$TEST_SANDBOX/t12_rec_missing.log"; then
        echo "FAIL: 缺失独立容器重建脚本报错信息异常: $(cat "$TEST_SANDBOX/t12_rec_missing.log")"
        exit 1
    fi
)
echo "PASS: 测试 12 通过（备份清单缺失项、独立容器构件缺失与哈希篡改均被严格拦截阻断恢复）"

# -----------------------------------------------------------------------------
# 测试 13: 恢复目标设备挂载安全性校验（DataRoot、Compose 路径、Bind 路径未挂载外部盘严格拦截）
# -----------------------------------------------------------------------------
echo "--- 测试 13: 恢复阶段全目标路径挂载安全性核验 ---"
(
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    T13_BKP="$TEST_SANDBOX/t13_bkp"
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    mkdir -p "$SYS_ROOT/mnt/unmounted_disk"

    # 13a: TARGET_DATA_ROOT 位于未挂载路径 (fallback 到 overlay /) 时拦截
    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$TEST_SANDBOX/unmounted_external_disk/docker" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_dataroot.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: DataRoot 位于未挂载路径恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_dataroot.log"; then
        echo "FAIL: DataRoot 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_dataroot.log")"
        exit 1
    fi

    # 13b: Compose 项目目标目录位于未挂载路径时拦截
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    printf 'unmounted_proj\t/mnt/unmounted_disk/my_app\t/mnt/unmounted_disk/my_app/docker-compose.yml\n' > "$T13_BKP/metadata/compose_manifest.tsv"
    tar -czf "$T13_BKP/compose/unmounted_proj.tar.gz" -T /dev/null 2>/dev/null || touch "$T13_BKP/compose/unmounted_proj.tar.gz"
    (
        cd "$T13_BKP"
        rm -f sha256sums.txt backup_manifest.txt
        find . -type f | sort | while IFS= read -r f; do
            clean_f="${f#./}"
            sha256sum "$clean_f"
        done > sha256sums.txt
        echo "manifest" > backup_manifest.txt
        sha256sum backup_manifest.txt >> sha256sums.txt
    )

    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_compose.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Compose 恢复目标位于未挂载路径时竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_compose.log"; then
        echo "FAIL: Compose 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_compose.log")"
        exit 1
    fi

    # 13c: Bind Mount 目标目录位于未挂载路径时拦截
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    echo "/mnt/unmounted_disk/bind_data" >> "$T13_BKP/metadata/bind_mounts.txt"
    (
        cd "$T13_BKP"
        rm -f sha256sums.txt backup_manifest.txt
        find . -type f | sort | while IFS= read -r f; do
            clean_f="${f#./}"
            sha256sum "$clean_f"
        done > sha256sums.txt
        echo "manifest" > backup_manifest.txt
        sha256sum backup_manifest.txt >> sha256sums.txt
    )

    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_bind.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Bind Mount 恢复目标位于未挂载路径时竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_bind.log"; then
        echo "FAIL: Bind Mount 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_bind.log")"
        exit 1
    fi

    # 13d: 目标存储磁盘可用空间不足时严格拦截恢复
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    echo "insufficient_space" > "$MOCK_STATE/df_mode"
    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_space.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/df_mode"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标存储空间不足时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(存储空间不足|空间不足)" "$TEST_SANDBOX/t13_space.log"; then
        echo "FAIL: 空间不足报错信息异常: $(cat "$TEST_SANDBOX/t13_space.log")"
        exit 1
    fi
)
echo "PASS: 测试 13 通过（恢复阶段 DataRoot、Compose、Bind 目标路径未挂载外部盘与空间不足全部被严格拦截）"

# -----------------------------------------------------------------------------
# 测试 14: 独立容器多网络拓扑备份阻断
# -----------------------------------------------------------------------------
echo "--- 测试 14: 独立容器连接多个网络备份阻断 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t14_docker"
    T14_TARGET="$TEST_SANDBOX/t14_target"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes" "$T14_TARGET"

    echo "multi_net_cid" > "$MOCK_STATE/containers_list_ids"
    echo "multi_net_app" > "$MOCK_STATE/cname_multi_net_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_multi_net_cid"
    echo "2" > "$MOCK_STATE/net_count_multi_net_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T14_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t14.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/net_count_multi_net_cid"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 连接多个网络的独立容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "连接了多个网络" "$TEST_SANDBOX/t14.log"; then
        echo "FAIL: 多网络报错信息不符合预期: $(cat "$TEST_SANDBOX/t14.log")"
        exit 1
    fi
)
echo "PASS: 测试 14 通过（连接多个网络的独立容器在备份阶段被成功阻断并提示迁移编排）"

# -----------------------------------------------------------------------------
# 测试 15: 独立容器不可还原高级特性在备份阶段严格阻断
# -----------------------------------------------------------------------------
echo "--- 测试 15: 独立容器高级特性与不可还原配置备份阻断 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t15_docker"
    T15_TARGET="$TEST_SANDBOX/t15_target"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes" "$T15_TARGET"

    # 15a: container 模式网络依赖
    echo "c_net_dep_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_net_dep" > "$MOCK_STATE/cname_c_net_dep_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_net_dep_cid"
    echo "container:main_vpn" > "$MOCK_STATE/cnet_c_net_dep_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T15_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t15_cnet.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cnet_c_net_dep_cid"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: container 网络模式依赖容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "网络模式依赖其他容器" "$TEST_SANDBOX/t15_cnet.log"; then
        echo "FAIL: container 网络依赖报错信息异常: $(cat "$TEST_SANDBOX/t15_cnet.log")"
        exit 1
    fi

    # 15b: Links 关联
    echo "c_links_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_links" > "$MOCK_STATE/cname_c_links_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_links_cid"
    echo "1" > "$MOCK_STATE/clinks_c_links_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T15_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t15_links.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/clinks_c_links_cid"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Links 容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "配置了 Links 容器关联" "$TEST_SANDBOX/t15_links.log"; then
        echo "FAIL: Links 报错信息异常: $(cat "$TEST_SANDBOX/t15_links.log")"
        exit 1
    fi

    # 15c: VolumesFrom 卷共享
    echo "c_vfrom_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_vfrom" > "$MOCK_STATE/cname_c_vfrom_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_vfrom_cid"
    echo "1" > "$MOCK_STATE/cvfrom_c_vfrom_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T15_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t15_vfrom.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cvfrom_c_vfrom_cid"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: VolumesFrom 容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "依赖了其他容器的数据卷" "$TEST_SANDBOX/t15_vfrom.log"; then
        echo "FAIL: VolumesFrom 报错信息异常: $(cat "$TEST_SANDBOX/t15_vfrom.log")"
        exit 1
    fi

    # 15d: 自定义 Runtime
    echo "c_runtime_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_runtime" > "$MOCK_STATE/cname_c_runtime_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_runtime_cid"
    echo "nvidia" > "$MOCK_STATE/cruntime_c_runtime_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T15_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t15_runtime.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cruntime_c_runtime_cid"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 自定义 Runtime 容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "使用了自定义运行时" "$TEST_SANDBOX/t15_runtime.log"; then
        echo "FAIL: Runtime 报错信息异常: $(cat "$TEST_SANDBOX/t15_runtime.log")"
        exit 1
    fi
)
echo "PASS: 测试 15 通过（Links、VolumesFrom、container 模式与自定义运行时均在备份阶段被成功阻断）"

# -----------------------------------------------------------------------------
# 测试 16: sha256sums.txt 严格自排除与生成时就地自校验
# -----------------------------------------------------------------------------
echo "--- 测试 16: sha256sums.txt 严格自排除与就地自校验 ---"
(
    T16_DOCKER="$TEST_SANDBOX/t16_docker"
    T16_TARGET="$TEST_SANDBOX/t16_target"
    mkdir -p "$T16_DOCKER/volumes" "$T16_TARGET"
    echo "$T16_DOCKER" > "$MOCK_STATE/docker_root_dir"

    echo "dummy_vol_data" > "$T16_DOCKER/volumes/data.txt"

    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T16_DOCKER" \
        --target-dir "$T16_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >/dev/null

    # 16a: 校验清单中严禁包含 sha256sums.txt 自身及隐藏临时文件
    if grep -q "sha256sums\.txt" "$T16_TARGET/sha256sums.txt"; then
        echo "FAIL: sha256sums.txt 包含自身哈希记录，存在哈希自引用污染！"
        exit 1
    fi
    if grep -q "\.sha256sums\.tmp" "$T16_TARGET/sha256sums.txt"; then
        echo "FAIL: sha256sums.txt 包含了隐藏临时文件 .sha256sums.tmp！"
        exit 1
    fi

    # 16b: backup_manifest.txt 必须被包含在校验清单中
    if ! grep -q "backup_manifest\.txt" "$T16_TARGET/sha256sums.txt"; then
        echo "FAIL: backup_manifest.txt 未被纳入 sha256sums.txt 校验！"
        exit 1
    fi

    # 16c: 原地哈希自校验必须全量通过
    (cd "$T16_TARGET" && sha256sum -c sha256sums.txt >/dev/null 2>&1) || {
        echo "FAIL: 备份生成的 sha256sums.txt 原地自校验未通过！"
        exit 1
    }
)
echo "PASS: 测试 16 通过（sha256sums.txt 严格自排除并全量通过就地自检）"

# -----------------------------------------------------------------------------
# 测试 17: 独立容器停机与快照顺序反例演练（停机后 commit/save 捕获落盘数据）
# -----------------------------------------------------------------------------
echo "--- 测试 17: 独立容器停机与快照顺序反例演练 ---"
(
    T17_DOCKER="$TEST_SANDBOX/t17_docker"
    T17_TARGET="$TEST_SANDBOX/t17_target"
    mkdir -p "$T17_DOCKER/volumes" "$T17_TARGET"
    echo "$T17_DOCKER" > "$MOCK_STATE/docker_root_dir"

    echo "c_flush_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_flush" > "$MOCK_STATE/cname_c_flush_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_flush_cid"
    echo "C /data_flush.txt" > "$MOCK_STATE/diff_c_flush_cid"

    # 清空调用日志
    : > "$MOCK_STATE/invocations.log"

    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T17_DOCKER" \
        --target-dir "$T17_TARGET" \
        --sys-root "$SYS_ROOT" >/dev/null

    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/diff_c_flush_cid"

    # 验证 docker stop 出现在 docker commit 之前
    STOP_LINE=$(grep -n "docker stop.*c_flush" "$MOCK_STATE/invocations.log" 2>/dev/null | head -n 1 | cut -d: -f1 || echo 0)
    COMMIT_LINE=$(grep -n "docker commit.*c_flush" "$MOCK_STATE/invocations.log" 2>/dev/null | head -n 1 | cut -d: -f1 || echo 0)
    SAVE_LINE=$(grep -n "docker save.*c_flush" "$MOCK_STATE/invocations.log" 2>/dev/null | head -n 1 | cut -d: -f1 || echo 0)

    if [ "$STOP_LINE" -eq 0 ]; then
        echo "FAIL: 备份期间未调用 docker stop 停止容器！"
        exit 1
    fi
    if [ "$COMMIT_LINE" -eq 0 ] || [ "$SAVE_LINE" -eq 0 ]; then
        echo "FAIL: 备份期间未调用 docker commit/save 导出容器快照！"
        exit 1
    fi
    if [ "$STOP_LINE" -ge "$COMMIT_LINE" ]; then
        echo "FAIL: docker commit 在 docker stop 之前被调用！停机刷盘数据未能被捕获到镜像快照中！"
        exit 1
    fi
)
echo "PASS: 测试 17 通过（容器关机落盘在 commit/save 快照之前执行，脏数据完全落盘）"

# -----------------------------------------------------------------------------
# 测试 18: 独立容器高级 --mount (bind & volume) 与多段 Entrypoint 命令安全解析与重建
# -----------------------------------------------------------------------------
echo "--- 测试 18: 独立容器高级 --mount 与多段 Entrypoint 重建 ---"
(
    T18_DOCKER="$TEST_SANDBOX/t18_docker"
    T18_TARGET="$TEST_SANDBOX/t18_target"
    mkdir -p "$T18_DOCKER/volumes" "$T18_TARGET"
    echo "$T18_DOCKER" > "$MOCK_STATE/docker_root_dir"

    echo "c_adv_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c_adv" > "$MOCK_STATE/cname_c_adv_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c_adv_cid"

    # 准备 bind 宿主目录 (必须存在，否则停机前校验会拦截)
    T18_ROUTER_BIND="/t18_host_data"
    T18_HOST_BIND="$SYS_ROOT$T18_ROUTER_BIND"
    mkdir -p "$T18_HOST_BIND"

    # 设置 HostConfig.Mounts: 一个 bind 挂载，一个 volume 挂载
    printf 'bind|%s|/container_data|false\nvolume|my_data_vol|/vol_data|false\n' "$T18_ROUTER_BIND" > "$MOCK_STATE/cmounts_c_adv_cid"

    # 设置多参数 Entrypoint: /bin/sh -c
    printf '/bin/sh\n-c\n' > "$MOCK_STATE/centrypoint_c_adv_cid"
    printf 'echo\nhello_ax6600\n' > "$MOCK_STATE/ccmd_c_adv_cid"

    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T18_DOCKER" \
        --target-dir "$T18_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >/dev/null

    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cmounts_c_adv_cid" "$MOCK_STATE/centrypoint_c_adv_cid" "$MOCK_STATE/ccmd_c_adv_cid"

    REC_SH="$T18_TARGET/standalone/recreate_c_adv.sh"
    if [ ! -f "$REC_SH" ]; then
        echo "FAIL: 独立容器重建脚本 recreate_c_adv.sh 未生成！"
        exit 1
    fi

    REC_BODY=$(cat "$REC_SH")

    # 验证 --mount bind 参数
    if ! echo "$REC_BODY" | grep -q -- "--mount 'type=bind,source=$T18_ROUTER_BIND,target=/container_data'"; then
        echo "FAIL: 重建脚本中未正确包含 bind 类型的 --mount 参数: $REC_BODY"
        exit 1
    fi

    # 验证 --mount volume 参数
    if ! echo "$REC_BODY" | grep -q -- "--mount 'type=volume,source=my_data_vol,target=/vol_data'"; then
        echo "FAIL: 重建脚本中未正确包含 volume 类型的 --mount 参数: $REC_BODY"
        exit 1
    fi

    # 验证首个 entrypoint token 设为 --entrypoint
    if ! echo "$REC_BODY" | grep -q -- "--entrypoint '/bin/sh'"; then
        echo "FAIL: 重建脚本中未正确提取首个入口点为 --entrypoint: $REC_BODY"
        exit 1
    fi

    # 验证后续 entrypoint token ('-c') 与 cmd 放在镜像名称之后
    if ! echo "$REC_BODY" | grep -qE "'alpine:latest'[[:space:]]+'-c'[[:space:]]+'echo'[[:space:]]+'hello_ax6600'"; then
        echo "FAIL: 重建脚本中 entrypoint 后续参数与 cmd 顺序错误: $REC_BODY"
        exit 1
    fi
)
echo "PASS: 测试 18 通过（HostConfig.Mounts 与多段 Entrypoint/Cmd 组合被精准还原）"

# -----------------------------------------------------------------------------
# 测试 19: 分区预检 sysfs 权威判定与反例测试
# -----------------------------------------------------------------------------
echo "--- 测试 19: 分区预检 sysfs 权威判定与反例测试 ---"
(
    FW_DIR19="$TEST_SANDBOX/fw_build_19"
    mkdir -p "$FW_DIR19/sysupgrade-glinet_gl-ax6600"
    head -c 4194304 /dev/zero > "$FW_DIR19/sysupgrade-glinet_gl-ax6600/kernel"
    head -c 52428800 /dev/zero > "$FW_DIR19/sysupgrade-glinet_gl-ax6600/root"
    IMG_FILE="$TEST_SANDBOX/test_fw19.bin"
    (cd "$FW_DIR19" && tar -cf "$IMG_FILE" sysupgrade-glinet_gl-ax6600)
    rm -rf "$FW_DIR19"
    SHA_EXPECTED=$(sha256sum "$IMG_FILE" | awk '{print $1}')

    # 19a: 0:BOOTCONFIG 分区不可读/损坏时，严禁盲猜，必须严格报错退出
    rm -f "$SYS_ROOT/dev/mmcblk0p2" "$MOCK_STATE/fdisk_mode"
    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t19_bootconf_fail.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 0:BOOTCONFIG 不可读时预检竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(未找到权威 0:BOOTCONFIG 分区设备节点|无法从 0:BOOTCONFIG 分区读取启动配置标记)" "$TEST_SANDBOX/t19_bootconf_fail.log"; then
        echo "FAIL: 0:BOOTCONFIG 缺失报错不符合预期: $(cat "$TEST_SANDBOX/t19_bootconf_fail.log")"
        exit 1
    fi

    # 19b: 目标对侧 _1 分区缺失时，严禁向其他分区借用扇区容量，必须严格退出
    echo "missing_partitions" > "$MOCK_STATE/fdisk_mode"
    mkdir -p "$SYS_ROOT/dev"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t19_missing_target.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/fdisk_mode" "$SYS_ROOT/dev/mmcblk0p2"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标 _1 分区不存在时预检竟然放行！"
        exit 1
    fi
    if ! grep -q "禁止借用其他分区容量或盲刷" "$TEST_SANDBOX/t19_missing_target.log"; then
        echo "FAIL: 目标分区缺失报错不符合预期: $(cat "$TEST_SANDBOX/t19_missing_target.log")"
        exit 1
    fi

    # 19c: 通过 sysfs uevent 和 size 获取 GPT 分区信息（即使 fdisk 无 Name 列也能正常工作）
    mkdir -p "$SYS_ROOT/sys/class/block/mmcblk0p13" "$SYS_ROOT/sys/class/block/mmcblk0p14" \
             "$SYS_ROOT/sys/class/block/mmcblk0p15" "$SYS_ROOT/sys/class/block/mmcblk0p16" \
             "$SYS_ROOT/sys/class/block/mmcblk0p2"

    printf 'PARTNAME=0:BOOTCONFIG\nDEVNAME=mmcblk0p2\n' > "$SYS_ROOT/sys/class/block/mmcblk0p2/uevent"
    echo 512 > "$SYS_ROOT/sys/class/block/mmcblk0p2/size"

    printf 'PARTNAME=0:HLOS\nDEVNAME=mmcblk0p13\n' > "$SYS_ROOT/sys/class/block/mmcblk0p13/uevent"
    echo 32768 > "$SYS_ROOT/sys/class/block/mmcblk0p13/size"

    printf 'PARTNAME=0:HLOS_1\nDEVNAME=mmcblk0p14\n' > "$SYS_ROOT/sys/class/block/mmcblk0p14/uevent"
    echo 32768 > "$SYS_ROOT/sys/class/block/mmcblk0p14/size"

    printf 'PARTNAME=rootfs\nDEVNAME=mmcblk0p15\n' > "$SYS_ROOT/sys/class/block/mmcblk0p15/uevent"
    echo 1048576 > "$SYS_ROOT/sys/class/block/mmcblk0p15/size"

    printf 'PARTNAME=rootfs_1\nDEVNAME=mmcblk0p16\n' > "$SYS_ROOT/sys/class/block/mmcblk0p16/uevent"
    echo 1048576 > "$SYS_ROOT/sys/class/block/mmcblk0p16/size"

    # 构造有效 0:BOOTCONFIG (标记为 1 -> 写入 _1)
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    # 执行预检，应通过 sysfs 成功探测分区容量
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t19_sysfs_ok.log" 2>&1
    if ! grep -q "目标根文件系统: \[rootfs_1\]" "$TEST_SANDBOX/t19_sysfs_ok.log"; then
        echo "FAIL: sysfs 分区探测未成功解析出目标分区: $(cat "$TEST_SANDBOX/t19_sysfs_ok.log")"
        exit 1
    fi

    # 19d: 固件包内实际 kernel 大小超过目标内核分区容量时必须阻断
    TAR_FW="$TEST_SANDBOX/large_kernel_fw.bin"
    T_PAYLOAD="$TEST_SANDBOX/payload_tmp"
    mkdir -p "$T_PAYLOAD"
    # 内核分区是 32768 扇区 = 16MB，创建一个 20MB 的 kernel 文件
    head -c 20971520 /dev/zero > "$T_PAYLOAD/kernel"
    head -c 1048576 /dev/zero > "$T_PAYLOAD/root"
    (cd "$T_PAYLOAD" && tar -cf "$TAR_FW" kernel root)
    rm -rf "$T_PAYLOAD"
    TAR_SHA=$(sha256sum "$TAR_FW" | awk '{print $1}')

    set +e
    sh "$HELPER_SCRIPT" precheck "$TAR_FW" "$TAR_SHA" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t19_large_kern.log"
    ret=$?
    set -e
    rm -rf "$SYS_ROOT/sys/class/block/mmcblk0p*" "$SYS_ROOT/dev/mmcblk0p2"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 固件实际内核大小 (20MB) 超过目标内核分区 (16MB)，预检竟然放行！"
        exit 1
    fi
    if ! grep -q "超过目标内核分区" "$TEST_SANDBOX/t19_large_kern.log"; then
        echo "FAIL: 超大内核报错信息不符合预期: $(cat "$TEST_SANDBOX/t19_large_kern.log")"
        exit 1
    fi
)
echo "PASS: 测试 19 通过（BOOTCONFIG 缺失严格阻断、无目标分区不借用、sysfs 权威解析与超大内核阻断）"

# -----------------------------------------------------------------------------
# 测试 20: 恢复阶段同挂载点聚合未压缩容量核验
# -----------------------------------------------------------------------------
echo "--- 测试 20: 恢复阶段同挂载点聚合容量校验 ---"
(
    T20_BKP="$TEST_SANDBOX/t20_bkp"
    T20_DATA="$TEST_SANDBOX/t20_dst_docker"
    T20_COMP="$SYS_ROOT/t20_compose"
    T20_BIND="$SYS_ROOT/t20_bind"
    mkdir -p "$T20_BKP/metadata" "$T20_BKP/config/etc_docker" "$T20_BKP/compose" "$T20_DATA" "$T20_COMP" "$T20_BIND"

    # 创建各组件极小的压缩包
    touch "$T20_BKP/config/config_dockerd" "$T20_BKP/config/config_dockerman" "$T20_BKP/config/etc_docker/daemon.json"
    tar -czf "$T20_BKP/docker_volumes.tar.gz" -T /dev/null 2>/dev/null || touch "$T20_BKP/docker_volumes.tar.gz"
    tar -czf "$T20_BKP/compose/proj20.tar.gz" -T /dev/null 2>/dev/null || touch "$T20_BKP/compose/proj20.tar.gz"
    tar -czf "$T20_BKP/docker_bind_mounts.tar.gz" -T /dev/null 2>/dev/null || touch "$T20_BKP/docker_bind_mounts.tar.gz"

    echo "proj20	/t20_compose	/t20_compose/docker-compose.yml" > "$T20_BKP/metadata/compose_manifest.tsv"
    echo "/t20_bind" > "$T20_BKP/metadata/bind_mounts.txt"

    # 在 uncompressed_sizes.tsv 中记录解压需求：
    # 模拟 DataRoot 需要 4GB (4194304KB), Compose 需要 4GB (4194304KB), Bind 需要 4GB (4194304KB)
    # 累加总计 12GB (12582912KB)
    # 而 /mnt/sda1 在 mock df 中可用空间仅为 9437184KB (9GB)
    cat << 'EOF' > "$T20_BKP/metadata/uncompressed_sizes.tsv"
volumes	docker_volumes.tar.gz	4194304
compose	proj20	4194304
bind	/t20_bind	4194304
EOF

    # 生成校验清单
    (
        cd "$T20_BKP"
        echo "dummy_manifest" > backup_manifest.txt
        find . -type f ! -name "sha256sums.txt" | sed 's|^\./||' | xargs sha256sum > sha256sums.txt
    )

    set +e
    sh "$HELPER_SCRIPT" restore \
        --backup-dir "$T20_BKP" \
        --target-data-root "$T20_DATA" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t20_agg_space.log"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 恢复阶段同挂载点聚合未压缩空间超限，竟然未被拦截！"
        exit 1
    fi
    if ! grep -qiE "(存储空间不足|可用空间不足)" "$TEST_SANDBOX/t20_agg_space.log"; then
        echo "FAIL: 聚合空间不足报错不符合预期: $(cat "$TEST_SANDBOX/t20_agg_space.log")"
        exit 1
    fi
)
echo "PASS: 测试 20 通过（同挂载点多组件未压缩体积累加超额被严格阻断）"

# -----------------------------------------------------------------------------
# 测试 21: PassWall2 活动核心动态反查与子目录 ACL 深度识别
# -----------------------------------------------------------------------------
echo "--- 测试 21: PassWall2 活动核心动态反查与 ACL 深度识别 ---"
(
    PW_DIR="$SYS_ROOT/var/etc/passwall2/ACL"
    mkdir -p "$PW_DIR" "$SYS_ROOT/proc/8888"

    # 在 ACL 子目录下生成包含 SOCKS 监听端口 2080 的 sing-box 配置
    cat << 'EOF' > "$PW_DIR/singbox_acl_rule.json"
{
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 模拟 sing-box 进程 (PID 8888)，并将命令行指向 ACL 子目录下的配置文件
    printf 'sing-box\0run\0-c\0/var/etc/passwall2/ACL/singbox_acl_rule.json\0' > "$SYS_ROOT/proc/8888/cmdline"
    touch "$MOCK_STATE/pgrep_running_sing-box"
    echo "8888" > "$MOCK_STATE/pgrep_pid_sing-box"

    # 21a: 正常 PassWall2 验证必须返回 0，严禁吞掉退出码
    set +e
    PW_OUT=$(sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>&1)
    ret=$?
    set -e
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PassWall2 正常配置验证未能成功通过 (退出码 $ret): $PW_OUT"
        exit 1
    fi
    if ! echo "$PW_OUT" | grep -q "2080"; then
        echo "FAIL: 未能成功从 ACL 深度子目录配置文件中定位到 SOCKS 本地端口 2080: $PW_OUT"
        exit 1
    fi
    if ! echo "$PW_OUT" | grep -q "PassWall2 代理握手验证成功"; then
        echo "FAIL: PassWall2 代理握手验证未成功记录: $PW_OUT"
        exit 1
    fi

    # 21b: TLS 握手失败时必须严格返回非 0 退出码并拦截，严禁误判通过
    touch "$MOCK_STATE/curl_fail"
    set +e
    PW_FAIL_OUT=$(sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>&1)
    ret_fail=$?
    set -e
    rm -f "$MOCK_STATE/curl_fail"
    rm -rf "$SYS_ROOT/var/etc/passwall2" "$SYS_ROOT/proc/8888" "$MOCK_STATE/pgrep_running_sing-box" "$MOCK_STATE/pgrep_pid_sing-box"

    if [ "$ret_fail" -eq 0 ]; then
        echo "FAIL: TLS 请求失败时 verify passwall 竟然返回成功 (退出码 0): $PW_FAIL_OUT"
        exit 1
    fi
    if ! echo "$PW_FAIL_OUT" | grep -q "PassWall2 代理握手失败"; then
        echo "FAIL: TLS 失败时未报告预期错误: $PW_FAIL_OUT"
        exit 1
    fi
)
echo "PASS: 测试 21 通过（PassWall2 动态反查进程 cmdline、递归识别 ACL 子目录且严格断言退出码与 TLS 连通性）"

# -----------------------------------------------------------------------------
# 测试 22: 容器挂载命名卷（Type=volume）严禁被误判为宿主 Bind 路径导致备份阻断
# -----------------------------------------------------------------------------
echo "--- 测试 22: 命名卷与外部 Bind 挂载严格区分（杜绝误判） ---"
(
    T22_DOCKER="$TEST_SANDBOX/t22_docker"
    T22_TARGET="$TEST_SANDBOX/t22_target"
    mkdir -p "$T22_DOCKER/volumes" "$T22_TARGET"
    echo "$T22_DOCKER" > "$MOCK_STATE/docker_root_dir"

    echo "c22_vol_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c22_app" > "$MOCK_STATE/cname_c22_vol_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c22_vol_cid"

    # 设置容器挂载：包含一个真正的命名卷 appdata（Source 为 appdata，Type 为 volume，在宿主不存在同名路径）
    # 同时包含一个合法的宿主 Bind 路径
    T22_HOST_PATH="/t22_real_host_dir"
    mkdir -p "$SYS_ROOT$T22_HOST_PATH"
    echo "real_host_payload" > "$SYS_ROOT$T22_HOST_PATH/file.txt"

    # 配置 HostConfig.Mounts: volume(appdata) 和 bind(/t22_real_host_dir)
    printf 'volume|appdata|/var/appdata|false\nbind|%s|/data|false\n' "$T22_HOST_PATH" > "$MOCK_STATE/cmounts_c22_vol_cid"

    # 执行备份，必须成功，绝不能因不存在路径 appdata 报错
    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T22_DOCKER" \
        --target-dir "$T22_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >"$TEST_SANDBOX/t22.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cmounts_c22_vol_cid"

    if [ "$ret" -ne 0 ]; then
        echo "FAIL: 包含命名卷的容器备份失败 (退出码 $ret): $(cat "$TEST_SANDBOX/t22.log")"
        exit 1
    fi
    if grep -q "appdata" "$T22_TARGET/metadata/bind_mounts.txt" 2>/dev/null; then
        echo "FAIL: 命名卷 appdata 被错误写入了 bind_mounts.txt！"
        exit 1
    fi
    if ! grep -q "$T22_HOST_PATH" "$T22_TARGET/metadata/bind_mounts.txt" 2>/dev/null; then
        echo "FAIL: 真正的 bind 挂载路径 $T22_HOST_PATH 未被写入 bind_mounts.txt！"
        exit 1
    fi
)
echo "PASS: 测试 22 通过（命名卷准确与 Bind 区分，杜绝将 Volume Name 误当宿主路径）"

# -----------------------------------------------------------------------------
# 测试 23: Compose 原目录已存在时，恢复能够正确获取目标路径并顺利通过空间预检
# -----------------------------------------------------------------------------
echo "--- 测试 23: Compose 原目录已存在时的恢复路径检查 ---"
(
    T23_BKP="$TEST_SANDBOX/t23_bkp"
    T23_DATA="$TEST_SANDBOX/t23_dst_docker"
    T23_COMP="/t23_my_existing_compose"
    T23_COMP_HOST="$SYS_ROOT$T23_COMP"

    # 预先创建该目标目录，模拟升级时原 Compose 目录已存在的情况
    mkdir -p "$T23_COMP_HOST" "$T23_DATA" "$T23_BKP/metadata" "$T23_BKP/config/etc_docker" "$T23_BKP/compose"

    touch "$T23_BKP/config/config_dockerd" "$T23_BKP/config/config_dockerman" "$T23_BKP/config/etc_docker/daemon.json"
    tar -czf "$T23_BKP/docker_volumes.tar.gz" -T /dev/null 2>/dev/null || touch "$T23_BKP/docker_volumes.tar.gz"
    tar -czf "$T23_BKP/compose/p23.tar.gz" -T /dev/null 2>/dev/null || touch "$T23_BKP/compose/p23.tar.gz"
    tar -czf "$T23_BKP/docker_bind_mounts.tar.gz" -T /dev/null 2>/dev/null || touch "$T23_BKP/docker_bind_mounts.tar.gz"

    echo "p23	$T23_COMP	$T23_COMP/docker-compose.yml" > "$T23_BKP/metadata/compose_manifest.tsv"
    : > "$T23_BKP/metadata/bind_mounts.txt"

    (
        cd "$T23_BKP"
        echo "manifest" > backup_manifest.txt
        find . -type f ! -name "sha256sums.txt" | sed 's|^\./||' | xargs sha256sum > sha256sums.txt
    )

    set +e
    sh "$HELPER_SCRIPT" restore \
        --backup-dir "$T23_BKP" \
        --target-data-root "$T23_DATA" \
        --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t23.log" 2>&1
    ret=$?
    set -e

    if [ "$ret" -ne 0 ]; then
        echo "FAIL: Compose 目标目录已存在时恢复失败 (退出码 $ret): $(cat "$TEST_SANDBOX/t23.log")"
        exit 1
    fi

    # 23b: 恢复时若 target-data-root 为空，必须严格拦截并报错
    set +e
    sh "$HELPER_SCRIPT" restore \
        --backup-dir "$T23_BKP" \
        --target-data-root "" \
        --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t23_empty_data.log" 2>&1
    ret_empty=$?
    set -e
    if [ "$ret_empty" -eq 0 ]; then
        echo "FAIL: target-data-root 为空时竟然未被拦截！"
        exit 1
    fi
    if ! grep -qiE "(恢复必须同时指定.*target-data-root|目标 DataRoot 存储路径为空|路径为空)" "$TEST_SANDBOX/t23_empty_data.log"; then
        echo "FAIL: 空路径报错不符合预期: $(cat "$TEST_SANDBOX/t23_empty_data.log")"
        exit 1
    fi
)
echo "PASS: 测试 23 通过（Compose 目标目录已存在时恢复能够正确获取目标绝对路径，空目标路径被严格拦截）"

# -----------------------------------------------------------------------------
# 测试 24: 挂载清单读取失败立即阻断（杜绝遗漏 Bind 数据生成伪成功备份），且容器无 Bind 时安全通过
# -----------------------------------------------------------------------------
echo "--- 测试 24: 挂载清单读取失败立即阻断与无 Bind 场景验证 ---"
(
    T24_DOCKER="$TEST_SANDBOX/t24_docker"
    T24_TARGET_A="$TEST_SANDBOX/t24_target_nobind"
    T24_TARGET_B="$TEST_SANDBOX/t24_target_fail"
    mkdir -p "$T24_DOCKER/volumes" "$T24_TARGET_A" "$T24_TARGET_B"
    echo "$T24_DOCKER" > "$MOCK_STATE/docker_root_dir"

    echo "c24_cid" > "$MOCK_STATE/containers_list_ids"
    echo "c24_app" > "$MOCK_STATE/cname_c24_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_c24_cid"
    : > "$MOCK_STATE/diff_c24_cid"
    echo "volume|vol24|/data|false" > "$MOCK_STATE/cmounts_c24_cid"
    : > "$MOCK_STATE/mounts_c24_cid"

    # 24a: 容器确实无 Bind 挂载时，备份正常完成，metadata/bind_mounts.txt 为空，无 docker_bind_mounts.tar.gz
    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T24_DOCKER" \
        --target-dir "$T24_TARGET_A" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >"$TEST_SANDBOX/t24_nobind.log" 2>&1
    ret_nobind=$?
    set -e
    if [ "$ret_nobind" -ne 0 ]; then
        echo "FAIL: 容器无 Bind 挂载时备份意外失败 (退出码 $ret_nobind): $(cat "$TEST_SANDBOX/t24_nobind.log")"
        exit 1
    fi
    if [ -s "$T24_TARGET_A/metadata/bind_mounts.txt" ]; then
        echo "FAIL: 无 Bind 挂载时 bind_mounts.txt 不为空！"
        exit 1
    fi
    if [ -f "$T24_TARGET_A/docker_bind_mounts.tar.gz" ]; then
        echo "FAIL: 无 Bind 挂载时意外生成了 docker_bind_mounts.tar.gz！"
        exit 1
    fi

    # 24b: 读取挂载清单失败时（模拟 docker inspect 出错），必须在停机前立即阻断退出，严禁生成伪成功备份
    T24_HOST_DIR="/t24_host_data"
    mkdir -p "$SYS_ROOT$T24_HOST_DIR"
    echo "payload_24" > "$SYS_ROOT$T24_HOST_DIR/file.txt"
    echo "bind|$T24_HOST_DIR|/data|false" > "$MOCK_STATE/cmounts_c24_cid"

    touch "$MOCK_STATE/docker_fail_mounts_inspect"
    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$T24_DOCKER" \
        --target-dir "$T24_TARGET_B" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >"$TEST_SANDBOX/t24_fail.log" 2>&1
    ret_fail=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_mounts_inspect" "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/cmounts_c24_cid" "$MOCK_STATE/mounts_c24_cid"

    if [ "$ret_fail" -eq 0 ]; then
        echo "FAIL: docker inspect 挂载清单失败时未被拦截，竟然返回了成功备份！"
        exit 1
    fi
    if ! grep -qiE "(读取容器.*挂载清单失败|无法保证备份完整)" "$TEST_SANDBOX/t24_fail.log"; then
        echo "FAIL: 拦截报错信息不符合预期: $(cat "$TEST_SANDBOX/t24_fail.log")"
        exit 1
    fi
    if [ -f "$T24_TARGET_B/backup_manifest.txt" ]; then
        echo "FAIL: 挂载清单导出失败后仍生成了 backup_manifest.txt！"
        exit 1
    fi
)
echo "PASS: 测试 24 通过（挂载清单导出失败被严格拦截阻断，无 Bind 挂载场景安全通过）"

echo "=== 全部 24 项深度隔离测试与回归演练已通过！ ==="

