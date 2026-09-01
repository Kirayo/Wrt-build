#!/usr/bin/env bash

set -euo pipefail

# ==============================
# Path
# ==============================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CORE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT_PATH=$(cd "$CORE_PATH/.." && pwd)
COMPILECFG_DIR="$CORE_PATH/compilecfg"

# ==============================
# Environment Variables
# ==============================
FORCE="${FORCE:-false}"
MANIFEST_CACHE='[]'          # 全局初始化
# 获取的最大Release数量
MAX_RELEASES=60
MAX_PARALLEL_DOWNLOADS=8   # 可根据情况调整，建议 4~10

# ==============================
# Check run
# ==============================
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "Error: only run on GitHub Actions" >&2
    exit 1
fi

# ==============================
# Check Dependencies
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
# Helpers
# ==============================
# Read INI file by key
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
            sub(/[ \t]*#.*$/, "", value)   # 去掉行尾注释
            print value
            exit
        }
        ' "$ini_file"
}

get_remote_commit() {
    local repo_url="$1"
    local branch="$2"

    git ls-remote --heads "$repo_url" "refs/heads/$branch" 2>/dev/null \
        | awk 'NR == 1 { print $1 }'
}

# ==============================
# Manifest cache
# ==============================
load_manifest_cache() {
    echo "Loading release manifests (latest ${MAX_RELEASES}, parallel=${MAX_PARALLEL_DOWNLOADS})..."

    local releases_json
    releases_json="$(
        gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=${MAX_RELEASES}" \
            --jq 'map(select(.draft == false and .prerelease == false))'
    )"

    local asset_ids
    asset_ids="$(
        jq -r '
            .[].assets[]
            | select(.name == "manifest.json" and .state == "uploaded")
            | .id
        ' <<< "$releases_json"
    )"

    if [[ -z "$asset_ids" ]]; then
        echo "Loaded 0 manifest(s)."
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    # 函数结束时自动清理
    trap 'rm -rf "$tmpdir"' RETURN

    # ---------- 并行下载 ----------
    # 把 asset_id 传给子 shell，下载到 $tmpdir/<id>.json
    echo "$asset_ids" | xargs -P "$MAX_PARALLEL_DOWNLOADS" -I{} \
        bash -c '
            asset_id="$1"
            outfile="$2/${asset_id}.json"
            if gh api \
                -H "Accept: application/octet-stream" \
                "repos/'"${GITHUB_REPOSITORY}"'/releases/assets/${asset_id}" \
                > "$outfile" 2>/dev/null; then
                # 下载成功，文件已存在
                :
            else
                # 下载失败，删除空文件并标记
                rm -f "$outfile"
                echo "::warning::无法读取 manifest.json (asset: ${asset_id})" >&2
            fi
        ' _ {} "$tmpdir"

    # ---------- 校验并合并 ----------
    local manifest
    for f in "$tmpdir"/*.json; do
        [[ -f "$f" ]] || continue

        manifest="$(<"$f")"

        if jq -e '.devices and (.devices | type == "object")' <<< "$manifest" >/dev/null 2>&1; then
            MANIFEST_CACHE="$(
                jq -c --argjson m "$manifest" '. + [$m]' <<< "$MANIFEST_CACHE"
            )"
        else
            local asset_id
            asset_id="$(basename "$f" .json)"
            echo "::warning::忽略无效 manifest.json (asset: ${asset_id})"
        fi
    done

    echo "Loaded $(jq 'length' <<< "$MANIFEST_CACHE") manifest(s)."
}

already_built() {
    local device="$1"
    local commit="$2"

    jq -e \
        --arg device "$device" \
        --arg commit "$commit" \
        'any(.[]; .devices[$device].commit == $commit)' \
        <<< "$MANIFEST_CACHE" \
        >/dev/null
}

# ==============================
# Device configs
# ==============================

# Read INI
if [ ! -d "$COMPILECFG_DIR" ]; then
    echo "Error: compilecfg directory not found: $COMPILECFG_DIR" >&2
    exit 1
fi

shopt -s nullglob

INI_FILES=("$COMPILECFG_DIR"/*.ini)

shopt -u nullglob

if [ "${#INI_FILES[@]}" -eq 0 ]; then
    echo "Error: no device configuration found in $COMPILECFG_DIR" >&2
    exit 1
fi

# 只有非 FORCE 才加载历史记录
if [ "$FORCE" != "true" ]; then
    echo "================================"
    echo " Check Previous Builds"
    echo " Repository : $GITHUB_REPOSITORY"
    echo " Releases   : latest $MAX_RELEASES"
    echo "================================"

    load_manifest_cache

fi

# ==============================
# Build Matrix
# ==============================
echo
echo "================================"
echo " Check Upstream Sources"
echo "================================"

MATRIX_ITEMS=()
RESOLVE_ERRORS=0

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

    if [ "$FORCE" != "true" ] && already_built "$device" "$commit"; then
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