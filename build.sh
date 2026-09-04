#!/usr/bin/env bash

set -e

# 以脚本自身定位，不依赖调用时的 CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/modules/network.sh" ]]; then
    CORE_PATH="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/core/modules/network.sh" ]]; then
    CORE_PATH="$(cd "$SCRIPT_DIR/core" && pwd)"
else
    echo "Error: core not found (from $SCRIPT_DIR)" >&2
    exit 1
fi


# 根目录
ROOT_PATH=$(cd "$CORE_PATH/.." && pwd)

DEVICE=$1
MODE=$2

BUILD_DATE=${BUILD_DATE:-$(TZ=Asia/Shanghai date +"%Y-%m-%d")}
BUILD_TIME=${BUILD_TIME:-$(TZ=Asia/Shanghai date +"%H:%M:%S")}

echo "================================"
echo "Device      : $DEVICE"
echo "Date        : $BUILD_DATE"
echo "Time        : $BUILD_TIME"
echo "Mode        : $MODE"
echo "================================"

SUPPORTED_DEVS=()

# 只有 compilecfg 与 deconfig 同名成对存在的设备才可构建。
collect_supported_devs() {
    local ini_file
    local dev_key
    local IFS

    SUPPORTED_DEVS=()

    for ini_file in "$CORE_PATH"/compilecfg/*.ini; do
        [[ -f "$ini_file" ]] || continue

        dev_key=$(basename "$ini_file" .ini)
        if [[ -f "$CORE_PATH/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        return
    fi

    IFS=$'\n' SUPPORTED_DEVS=($(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort))
}

print_usage() {
    echo "Usage: $0 <device> [normal|debug|config_preview]"
    echo "       ./build.sh"
}

print_supported_devs() {
    local index

    echo "Supported devices:"
    for ((index = 0; index < ${#SUPPORTED_DEVS[@]}; index++)); do
        printf "  %d) %s\n" "$((index + 1))" "${SUPPORTED_DEVS[index]}"
    done
}

prompt_select_dev() {
    local input
    local selected_index

    while true; do
        print_supported_devs
        printf "Select device by number (q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            selected_index=${BASH_REMATCH[1]}
            if ((selected_index >= 1 && selected_index <= ${#SUPPORTED_DEVS[@]})); then
                DEVICE=${SUPPORTED_DEVS[selected_index - 1]}
                return
            fi
        fi

        echo "Invalid selection. Please enter a number between 1 and ${#SUPPORTED_DEVS[@]}."
    done
}

prompt_select_build_mode() {
    local input

    while true; do
        echo "Build mode:"
        echo "  1) normal"
        echo "  2) debug"
        echo "  3) config_preview"
        printf "Select build mode (1-5, q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
            MODE="normal"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*2[[:space:]]*$ ]]; then
            MODE="debug"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*3[[:space:]]*$ ]]; then
            MODE="config_preview"
            return
        fi

        echo "Invalid selection. Please enter 1, 2, 3"
    done
}
# 判断是否支持交互终端
is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}
# 校验模式
validate_build_mode() {
    case "$MODE" in
        normal|debug|config_preview)
            return 0
            ;;
        *)
            echo "Error: unsupported build mode: $MODE" >&2
            print_usage >&2
            exit 1
            ;;
    esac
}

if [[ $# -eq 0 ]]; then
    collect_supported_devs

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        echo "Error: no supported devices found."
        exit 1
    fi

    if ! is_interactive_terminal; then
        print_usage
        print_supported_devs
        exit 1
    fi

    prompt_select_dev

    if [[ -z $MODE ]]; then
        prompt_select_build_mode
    fi
fi

CONFIG_FILE="$CORE_PATH/deconfig/$DEVICE.config"
INI_FILE="$CORE_PATH/compilecfg/$DEVICE.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

validate_build_mode

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

CONFIG_FRAGMENT_DIR="$CORE_PATH/deconfig/fragments"
CONFIG_FRAGMENTS=()

parse_fragment_csv() {
    local csv=$1
    local output_array=$2
    local item
    local -n target_array="$output_array"

    target_array=()
    csv=${csv//[[:space:]]/}

    [[ -n $csv ]] || return 0

    IFS=',' read -r -a target_array <<< "$csv"

    for item in "${target_array[@]}"; do
        if [[ -z $item ]]; then
            echo "Error: empty config fragment name in '$csv'." >&2
            exit 1
        fi

        if [[ ! $item =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            echo "Error: invalid config fragment name '$item'." >&2
            exit 1
        fi
    done
}

validate_enable_fragment() {
    local fragment=$1
    local fragment_path="$CONFIG_FRAGMENT_DIR/$fragment.config"

    if [[ ! -f $fragment_path ]]; then
        echo "Error: config fragment not found: $fragment_path" >&2
        exit 1
    fi
}

join_fragments() {
    local IFS=','
    echo "$*"
}
# 校验 CONFIG_FRAGMENTS 是否有效
resolve_config_fragments() {
    local fragment

    parse_fragment_csv "$(read_ini_by_key "CONFIG_FRAGMENTS")" CONFIG_FRAGMENTS

    for fragment in "${CONFIG_FRAGMENTS[@]}"; do
        validate_enable_fragment "$fragment"
    done

}

print_config_fragment_summary() {
    echo "Config fragments:"
    echo "  Device: $DEVICE"
    echo "  Enabled fragments: $(join_fragments "${CONFIG_FRAGMENTS[@]}")"
}

print_config_preview() {
    print_config_fragment_summary
    echo "Config assembly order:"
    echo "  1) $CONFIG_FILE"
    echo "  2) $CORE_PATH/deconfig/compile_base.config"

    local order=3
    local fragment
    for fragment in "${CONFIG_FRAGMENTS[@]}"; do
        echo "  $order) $CONFIG_FRAGMENT_DIR/$fragment.config"
        order=$((order + 1))
    done

}

remove_uhttpd_dependency() {
    local config_path="$BUILD_PATH/.config"
    local luci_makefile_path="$BUILD_PATH/feeds/luci/collections/luci/Makefile"

    [[ -f "$config_path" ]] || return 0
    grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path" || return 0
    [[ -f "$luci_makefile_path" ]] || return 0

    sed -i '/luci-light/d' "$luci_makefile_path"
    echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
}

#  精细化修改 99-default-settings-chinese 的预处理函数
apply_repo_modifications() {
    local target_script="$BUILD_PATH/package/emortal/default-settings/files/99-default-settings-chinese"

    if [ -f "$target_script" ]; then
        echo "正在注入 99-default-settings-chinese 源删改逻辑..."

        # 在 exit 0 前注入删改命令：
        # - 删除 nss_packages 和 sqm_scripts_nss
        # - 匹配包含 /video 的行，不依赖原域名，直接将协议+主机名部分替换为上海交大镜像源
        sed -i "/exit 0/i\\
# --- 自定义 APK/OPKG 软件源删改逻辑 ---\\
if [ -f /etc/apk/repositories ]; then\\
    sed -i '/nss_packages/d' /etc/apk/repositories\\
    sed -i '/sqm_scripts_nss/d' /etc/apk/repositories\\
    sed -i '/\/video/s|https://[^/]*/|https://mirror.sjtu.edu.cn/|g' /etc/apk/repositories\\
fi\\
\\
if [ -f /etc/opkg/distfeeds.conf ]; then\\
    sed -i '/nss_packages/d' /etc/opkg/distfeeds.conf\\
    sed -i '/sqm_scripts_nss/d' /etc/opkg/distfeeds.conf\\
    sed -i '/\/video/s|https://[^/]*/|https://mirror.sjtu.edu.cn/|g' /etc/opkg/distfeeds.conf\\
fi\\
" "$target_script"
    else
        echo "警告: 未找到 $target_script，跳过源修改。"
    fi
}

assemble_config() {
    local fragment
    local config_path="$BUILD_PATH/.config"

    # 1. 先清空（或重新创建）目标 .config 文件
    > "$config_path"

    # 2. 先写入公共基础配置 compile_base.config
    if [ -f "$CORE_PATH/deconfig/compile_base.config" ]; then
        cat "$CORE_PATH/deconfig/compile_base.config" >> "$config_path"
    fi

    # 3. 接着追加各种功能片段配置 (CONFIG_FRAGMENTS)
    for fragment in "${CONFIG_FRAGMENTS[@]}"; do
        if [ -f "$CONFIG_FRAGMENT_DIR/$fragment.config" ]; then
            cat "$CONFIG_FRAGMENT_DIR/$fragment.config" >> "$config_path"
        fi
    done

    # 4. 最后追加主配置文件 CONFIG_FILE（确保它的优先级最高，覆盖前面的重复项）
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE" >> "$config_path"
    fi
}

# 读取设备元信息，确定上游源码和构建目录。
REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

resolve_config_fragments

if [[ $MODE == "config_preview" ]]; then
    print_config_preview
    exit 0
fi

# 下游
"$CORE_PATH/scripts/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH"

# 构建目录
if [[ "$GITHUB_ACTIONS" == "true" && -z "$BUILD_DIR" ]]; then
    BUILD_DIR="actions-build"
fi

if [[ -z "$BUILD_DIR" ]]; then
    echo "Error: BUILD_DIR is not set" >&2
    exit 1
fi

BUILD_PATH="$(realpath "$ROOT_PATH/$BUILD_DIR")"

# 合并处理config
apply_repo_modifications
assemble_config
print_config_fragment_summary
remove_uhttpd_dependency

cd "$BUILD_PATH"

# x86 feed 修正
if grep -qE "^CONFIG_TARGET_x86_64=y" "$BUILD_PATH/.config"; then
    DISTFEEDS_PATH="$BUILD_PATH/package/emortal/default-settings/files/99-distfeeds.conf"

    if [[ -f "$DISTFEEDS_PATH" ]]; then
        echo "Fix x86_64 distfeeds"
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

echo "Running make defconfig"
make defconfig

if [[ "$MODE" == "debug" ]]; then
    DEBUG_DIR="$ROOT_PATH/output/debug"
    mkdir -p "$DEBUG_DIR"

    # Export diffconfig
    "$BUILD_PATH/scripts/diffconfig.sh" \
        > "$DEBUG_DIR/${DEVICE}.diffconfig"

    # Export complete config after make defconfig
    cp "$BUILD_PATH/.config" \
        "$DEBUG_DIR/${DEVICE}.config"

    echo "========== OUTPUT =========="
    echo "Diffconfig : $DEBUG_DIR/${DEVICE}.diffconfig"
    echo "Config     : $DEBUG_DIR/${DEVICE}.config"

    exit 0
fi

# ==============================
# Cleanup old images
# ==============================

TARGET_DIR="$BUILD_PATH/bin/targets"

if [[ -d "$TARGET_DIR" ]]; then
   rm -rf "$TARGET_DIR"
fi

# ==============================
# Build
# ==============================
CPU_CORES=$(nproc)
DOWNLOAD_JOBS=$((CPU_CORES * 2))
BUILD_JOBS=$((CPU_CORES + 1))

echo "Download jobs: $DOWNLOAD_JOBS"
echo "Build jobs   : $BUILD_JOBS"

make download -j"$DOWNLOAD_JOBS"
make -j"$BUILD_JOBS" || make -j1 V=s

# ==============================
# Build Artifacts
# ==============================
echo "================================"
echo " Build File"
ls -lh "$TARGET_DIR"
echo "================================"

OUTPUT_DIR="$ROOT_PATH/output"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

while IFS= read -r file; do

    cp "$file" "$OUTPUT_DIR/"

done < <(
    find "$TARGET_DIR" -type f \
    -not -path "*/packages/*"
)

echo
echo "================================"
echo "Output File"
ls -lh "$OUTPUT_DIR"
echo "================================"