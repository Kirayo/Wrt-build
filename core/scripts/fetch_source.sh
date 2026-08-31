#!/usr/bin/env bash

set -e
set -o pipefail

# ==============================
# Path
# ==============================
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_PATH="$(cd "$SCRIPT_PATH/.." && pwd)"
ROOT_PATH=$(cd "$CORE_PATH/.." && pwd)

# ==============================
# Load network module
# ==============================
source "$CORE_PATH/modules/network.sh"

# ==============================
# Device
# ==============================
DEV="$1"

if [ -z "$DEV" ]; then
    echo "Error: device model is required"
    exit 1
fi

# Optional source commit.
#
# Old/manual workflow:
#   fetch_source-code.sh DEVICE
#   -> clone REPO_BRANCH HEAD
#
# Auto build:
#   fetch_source-code.sh DEVICE COMMIT
#   -> fetch and checkout exact commit
#
# Environment variable SOURCE_COMMIT is also supported.
SOURCE_COMMIT="${2:-${SOURCE_COMMIT:-}}"

# ==============================
# Device config
# ==============================
INI_FILE="$CORE_PATH/compilecfg/${DEV}.ini"

if [ ! -f "$INI_FILE" ]; then
    echo "INI file not found:"
    echo "$INI_FILE"
    exit 1
fi

# ==============================
# Read INI value
# ==============================
read_ini_by_key() {
    local key="$1"

    awk -F'=' \
        -v key="$key" \
        '
        $1 ~ "^[ \t]*"key"[ \t]*$" {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
        }
        ' "$INI_FILE"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")

if [ -z "$REPO_URL" ]; then
    echo "Error: REPO_URL missing in $INI_FILE"
    exit 1
fi

if [ -z "$BUILD_DIR" ]; then
    echo "Warn: BUILD_DIR missing in $INI_FILE , default: actions-build"
    BUILD_DIR="actions-build"
fi

BUILD_PATH="$ROOT_PATH/$BUILD_DIR"
BUILD_PATH=$(realpath "$BUILD_PATH")

# ==============================
# Display configuration
# ==============================
echo "================================"
echo " Fetch Source Code"
echo "================================"
echo "Device : $DEV"
echo "Repo   : $REPO_URL"
echo "Branch : $REPO_BRANCH"
echo "Build  : $BUILD_PATH"

if [ -n "$SOURCE_COMMIT" ]; then
    echo "Commit : $SOURCE_COMMIT"
    echo "Mode   : exact commit"
else
    echo "Commit : latest"
    echo "Mode   : branch HEAD"
fi

echo "=============================="

# ==============================
# Clean old source
# ==============================
if [ -d "$BUILD_PATH" ]; then
    echo "Removing old build directory..."
    rm -rf "$BUILD_PATH"
fi

# ==============================
# Fetch source
# ==============================
if [ -n "$SOURCE_COMMIT" ]; then
    echo "Fetching exact source commit: $SOURCE_COMMIT"

    mkdir -p "$BUILD_PATH"

    git -C "$BUILD_PATH" init
    git -C "$BUILD_PATH" remote add origin "$REPO_URL"
    git_retry -C "$BUILD_PATH" fetch \
        --depth 1 \
        origin "$SOURCE_COMMIT"
    git -C "$BUILD_PATH" checkout --detach "$SOURCE_COMMIT"

else
    echo "Fetching branch HEAD..."
    git_retry clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$BUILD_PATH"

fi

# ==============================
# Verify source commit
# 校验 commit是否一致
# ==============================
ACTUAL_COMMIT=$(git -C "$BUILD_PATH" rev-parse HEAD)

echo "================================"
echo " Source Verification"
echo "================================"

if [ -n "$SOURCE_COMMIT" ]; then
    echo "Expected : $SOURCE_COMMIT"
else
    echo "Expected : branch HEAD"
fi

echo "Actual   : $ACTUAL_COMMIT"
echo "================================"

if [ -n "$SOURCE_COMMIT" ] &&
   [ "$ACTUAL_COMMIT" != "$SOURCE_COMMIT" ]; then
    echo "Error: source commit mismatch!" >&2
    exit 1
fi
# ==============================
# GitHub Actions
# ==============================
if [ -n "$GITHUB_ACTIONS" ]; then
    # 导出
    echo "BUILD_DATE=$(TZ=Asia/Shanghai date +"%Y-%m-%d")" >> "$GITHUB_OUTPUT"
    echo "BUILD_DIR=$BUILD_DIR" >> "$GITHUB_OUTPUT"
    echo "SOURCE_COMMIT=$ACTUAL_COMMIT" >> "$GITHUB_OUTPUT"

    # 移除国内下载源
    PROJECT_MIRRORS_FILE="$BUILD_PATH/scripts/projectsmirrors.json"

    if [ -f "$PROJECT_MIRRORS_FILE" ]; then
        sed -i \
            -e '/mirrors.aliyun.com/d' \
            -e '/mirrors.tencent.com/d' \
            -e '/\.cn/d' \
            "$PROJECT_MIRRORS_FILE"
    fi
fi

echo "Fetch Source Code completed."
