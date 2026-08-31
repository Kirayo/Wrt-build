#!/usr/bin/env bash

set -euo pipefail

# ==============================
# Path
# ==============================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CORE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT_PATH=$(cd "$CORE_PATH/.." && pwd)
COMPILECFG_DIR="$CORE_PATH/compilecfg"

FORCE="${FORCE:-false}"

# ==============================
# Check run environment
# ==============================
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "Error: only run on GitHub Actions" >&2
    exit 1
fi

# ==============================
# Check dependencies
# ==============================
command -v git >/dev/null 2>&1 || {
    echo "Error: git is required" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || {
    echo "Error: GitHub CLI (gh) is required" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required" >&2
    exit 1
}

# ==============================
# Read INI
# ==============================
if [ ! -d "$COMPILECFG_DIR" ]; then
    echo "Error: compilecfg directory not found: $COMPILECFG_DIR" >&2
    exit 1
fi

read_ini_by_key() {
    local ini_file="$1"
    local key="$2"

    awk -F'=' \
        -v key="$key" \
        '
        $1 ~ "^[ \t]*" key "[ \t]*$" {
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            print value
            exit
        }
        ' "$ini_file"
}

# ==============================
# Get upstream commit
# ==============================
get_remote_commit() {
    local repo_url="$1"
    local branch="$2"

    git ls-remote "$repo_url" "refs/heads/$branch" \
        | awk 'NR == 1 { print $1 }'
}

# ==============================
# Device configs
# ==============================
shopt -s nullglob

INI_FILES=("$COMPILECFG_DIR"/*.ini)

if [ "${#INI_FILES[@]}" -eq 0 ]; then
    echo "Error: no device configuration found:"
    echo "$COMPILECFG_DIR" >&2
    exit 1
fi

# ==============================
# Previous releases（一次 API）
#
# 用来判断「这台设备的这个 commit 最近是否已经发过」。
# 不能只看最新一份 Release：那天可能只编了其中一台。
#
# 匹配两种痕迹（新旧包都能认）：
#   1. 旧文件名：DEVICE-SHORTSHA-*
#   2. 新 notes：| DEVICE | `40位commit` |
# ==============================
RELEASES_JSON="[]"

if [ "$FORCE" != "true" ]; then
    echo "================================"
    echo " Check Previous Builds"
    echo " Repository : $GITHUB_REPOSITORY"
    echo " Releases   : latest 60"
    echo "================================"

    RELEASES_JSON="$(
        gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=60" \
            --jq '[.[] | {body: (.body // ""), assets: [.assets[].name]}]'
    )"
fi

already_built() {
    local device="$1"
    local commit="$2"
    local short_commit="$3"

    jq -e \
        --arg device "$device" \
        --arg commit "$commit" \
        --arg prefix "${device}-${short_commit}-" \
        --arg marker "| ${device} | \`${commit} |" \
        'any(.[];
            any(.assets[]; startswith($prefix))
            or ((.body // "") | contains($marker))
        )' \
        <<< "$RELEASES_JSON" \
        >/dev/null
}

# ==============================
# Build Matrix
# ==============================
MATRIX_ITEMS=()
RESOLVE_ERRORS=0

echo
echo "================================"
echo " Check Upstream Sources"
echo "================================"

for ini_file in "${INI_FILES[@]}"; do
    device="$(basename "$ini_file" .ini)"

    repo_url="$(read_ini_by_key "$ini_file" "REPO_URL")"
    repo_branch="$(read_ini_by_key "$ini_file" "REPO_BRANCH")"
    repo_branch="${repo_branch:-main}"
    build_dir="$(read_ini_by_key "$ini_file" "BUILD_DIR")"

    echo
    echo "[$device]"

    if [ -z "$repo_url" ]; then
        echo "  Status     : ERROR - REPO_URL missing"
        RESOLVE_ERRORS=$((RESOLVE_ERRORS + 1))
        continue
    fi

    if [ -z "$build_dir" ]; then
        echo "  Status     : ERROR - BUILD_DIR missing"
        RESOLVE_ERRORS=$((RESOLVE_ERRORS + 1))
        continue
    fi

    commit="$(get_remote_commit "$repo_url" "$repo_branch")"

    if [ -z "$commit" ]; then
        echo "  Status     : ERROR - unable to get upstream commit"
        RESOLVE_ERRORS=$((RESOLVE_ERRORS + 1))
        continue
    fi

    short_commit="${commit:0:7}"
    echo "  Repo       : $repo_url"
    echo "  Branch     : $repo_branch"
    echo "  Commit     : $short_commit"
    echo "  Build dir  : $build_dir"

    if [ "$FORCE" != "true" ] && already_built "$device" "$commit" "$short_commit"; then
        echo "  Status     : already built"
        continue
    fi

    echo "  Status     : build required"

    # 注意：最后一项 --arg 后面必须有 \，否则 { } 不会传给 jq
    MATRIX_ITEMS+=(
        "$(jq -cn \
            --arg model "$device" \
            --arg source "$repo_url" \
            --arg branch "$repo_branch" \
            --arg commit "$commit" \
            --arg short_commit "$short_commit" \
            --arg build_dir "$build_dir" \
            '{
                model: $model,
                source: $source,
                branch: $branch,
                commit: $commit,
                short_commit: $short_commit,
                build_dir: $build_dir
            }')"
    )
done

if [ "$RESOLVE_ERRORS" -gt 0 ] && [ "${#MATRIX_ITEMS[@]}" -eq 0 ]; then
    echo "Error: all devices failed to resolve" >&2
    exit 1
fi

# ==============================
# Generate Matrix
# ==============================
if [ "${#MATRIX_ITEMS[@]}" -eq 0 ]; then
    # 空 include 会让 GHA 的 fromJSON 直接失败；占位 + has_updates=false
    MATRIX='{"include":[{"model":"_none","source":"none","branch":"none","commit":"none","short_commit":"none","build_dir":"none"}]}'
    HAS_UPDATES="false"
else
    MATRIX="$(
        printf '%s\n' "${MATRIX_ITEMS[@]}" |
            jq -sc '{include: .}'
    )"
    HAS_UPDATES="true"
fi

# ==============================
# Result
# ==============================
echo
echo "================================"
echo " Update Check Result"
echo "================================"
echo "Has updates : $HAS_UPDATES"
echo "Force       : $FORCE"
echo
echo "Matrix:"
echo "$MATRIX" | jq .

# ==============================
# GitHub Actions Outputs
# ==============================
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "matrix<<EOF"
        echo "$MATRIX"
        echo "EOF"
        echo "has_updates=$HAS_UPDATES"
    } >> "$GITHUB_OUTPUT"
fi