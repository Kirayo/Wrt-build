#!/usr/bin/env bash

get_feeds_path() {
    local feeds_path="$BUILD_PATH/$FEEDS_CONF"
    if [[ -f "$BUILD_PATH/feeds.conf" ]]; then
        feeds_path="$BUILD_PATH/feeds.conf"
    fi
    printf '%s\n' "$feeds_path"
}

append_feed_if_missing() {
    local feeds_path="$1"
    local match_pattern="$2"
    local feed_entry="$3"

    if ! grep -q "$match_pattern" "$feeds_path"; then
        [ -z "$(tail -c 1 "$feeds_path")" ] || echo "" >>"$feeds_path"
        echo "$feed_entry" >>"$feeds_path"
    fi
}

update_feeds() {
    # local FEEDS_PATH
    # FEEDS_PATH=$(get_feeds_path)
    # # 调试
    # echo "FEEDS_PATH : $FEEDS_PATH"
    # sed -i '/^#/d' "$FEEDS_PATH"
    # sed -i '/packages_ext/d' "$FEEDS_PATH"
    # sed -i '/[[:space:]]small8[[:space:]]/d' "$FEEDS_PATH"
    # sed -i '/[[:space:]]custom_feed[[:space:]]/d' "$FEEDS_PATH"

    # append_feed_if_missing "$FEEDS_PATH" "openwrt_bandix" "src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main"
    # append_feed_if_missing "$FEEDS_PATH" "luci_app_bandix" "src-git luci_app_bandix https://github.com/timsaya/luci-app-bandix.git;main"

    # if [ ! -f "$BUILD_PATH/include/bpf.mk" ]; then
    #     touch "$BUILD_PATH/include/bpf.mk"
    # fi

    echo "正在更新 feeds 配置与索引..."

    # 确保切换到正确的源码根目录
    cd "${BUILD_PATH:-.}" || return 1

    # 使用 -f -a 强制更新所有源，防止 git 冲突导致 CI 中断
    ./scripts/feeds update -f -a
}

install_feeds() {
    echo "正在安装所有 feeds 软件包..."

    # 确保在源码根目录下执行
    cd "${BUILD_PATH:-.}" || return 1

    # 配合 -f 强制重新建立符号链接，覆盖旧的同名包
    ./scripts/feeds install -f -a
}
