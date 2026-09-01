#!/usr/bin/env bash

set -Ee

# 错误处理
error_handler() {
    local exit_code=$?
    echo
    echo "ERROR:"
    echo "  Script : ${BASH_SOURCE[1]}"
    echo "  Line   : ${BASH_LINENO[0]}"
    echo "  Command: ${BASH_COMMAND}"
    echo "  Code   : $exit_code"
}

trap error_handler ERR

#######################################
# 参数
if [[ $# -lt 3 ]]; then
    echo "Usage:"
    echo "  $0 <repo_url> <branch> <build_dir> [commit_hash]"
    exit 1
fi

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4

#######################################
# 路径
# 以脚本自身定位，不依赖调用时的 CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# core
CORE_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
# 根
ROOT_PATH="$(cd "$CORE_PATH/.." && pwd)"
# 构建目录
BUILD_PATH="$(realpath "$ROOT_PATH/$BUILD_DIR")"
# 模块目录
MODULE_PATH="$(cd "$CORE_PATH/modules" && pwd)"

#######################################
# 默认ip地址
LAN_ADDR="192.168.0.1"
FEEDS_CONF="feeds.conf.default"

# 模块
# 按静态职责加载模块，执行顺序仍由本脚本统一控制。
source "$MODULE_PATH/network.sh"
source "$MODULE_PATH/repo.sh"
source "$MODULE_PATH/feeds.sh"
source "$MODULE_PATH/custom_feed.sh"
source "$MODULE_PATH/verify.sh"
source "$MODULE_PATH/docker.sh"
source "$MODULE_PATH/cups.sh"
source "$MODULE_PATH/feed_source_fixes.sh"
source "$MODULE_PATH/package_source_updates.sh"
source "$MODULE_PATH/target_fixes.sh"
source "$MODULE_PATH/luci_fixes.sh"
source "$MODULE_PATH/service_fixes.sh"

# 阶段顺序不可随意调整：feeds install 前后依赖的目录不同。
stage_repo_checkout() {
    # 从干净的上游源码树开始，保证后续修正基线一致。
    clone_repo
    clean_up
    reset_feeds_conf
}

stage_upstream_feeds_update() {
    # 先生成上游 feeds/* 工作树。
    update_feeds
}

stage_feed_source_cleanup() {
    # 清理会与 custom_feed 替换包冲突的上游 feed 包。
    # remove_unwanted_packages
    # remove_tweaked_packages
}

stage_custom_feed_prepare() {
    # custom_feed 以 src-link 加入 feeds，仍属于 install 前阶段。
    # install_custom_feed
}

stage_pre_install_source_fixes() {
    # 这里仅修改源码树与 feeds/*，不能依赖 package/feeds/*。
    # update_homeproxy
    # fix_default_set
    # fix_miniupnpd
    # update_golang
    # change_dnsmasq2full
    # fix_mk_def_depends

    update_default_lan_addr
    # remove_something_nss_kmod
    # update_affinity_script
    # update_ath11k_fw
    # fix_mkpkg_format_invalid
    # change_cpuusage
    # update_tcping
    # add_ax6600_led
    # set_custom_task
    # apply_passwall_tweaks
    # update_nss_pbuf_performance
    set_build_signature
    # update_nss_diag
    # update_menu_location
    # fix_compile_coremark
    # update_dnsmasq_conf
    # add_backup_info_to_sysupgrade
    # update_mosdns_deconfig
    # fix_quickstart
    # update_oaf_deconfig
    # add_timecontrol
    # add_quickfile
    # update_lucky
    # fix_rust_compile_error
    # update_smartdns
    # update_mwan3_fw4
    # update_diskman
    # update_dockerman
    # set_nginx_default_config
    # update_uwsgi_limit_as
    # update_argon
    # update_nginx_ubus_module
    check_default_settings
    # install_opkg_distfeeds
    # fix_easytier_mk
    remove_attendedsysupgrade
    # fix_kconfig_recursive_dependency
}

stage_feeds_install() {
    # install 后才会生成 package/feeds/*。
    install_feeds
}

stage_post_install_package_fixes() {
    # 这里处理已安装到 package/feeds/* 的包和最终一致性检查。
    # verify_custom_feed_installed_paths
    # docker_stack_sync_nftables_compat "$BUILD_PATH" "0"
    # fix_cups_libcups_avahi_depends
    # fix_easytier_lua
    # update_adguardhome
    # update_script_priority
    # update_geoip
    # fix_openssl_ktls
    # fix_opkg_check
    # fix_netfilter_kmod_clash
    # fix_quectel_cm
    # install_pbr_cmcc
    # fix_pbr_ip_forward
    # apply_hash_fixes
}

main() {
    stage_repo_checkout
    stage_upstream_feeds_update
    stage_pre_install_source_fixes
    stage_feeds_install
}

main "$@"
