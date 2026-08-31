#!/usr/bin/env bash
# 上游源码拉取、清理和复位。

clone_repo() {
    if [[ ! -d "$BUILD_PATH" ]]; then
        echo "克隆仓库: $REPO_URL 分支: $REPO_BRANCH"

        if ! git_retry clone \
            --depth 1 \
            -b "$REPO_BRANCH" \
            "$REPO_URL" \
            "$BUILD_PATH"; then
            echo "错误：克隆仓库 $REPO_URL 失败" >&2
            exit 1
        fi
    fi
}

clean_up() {
    if [[ ! -d "$BUILD_PATH" ]]; then
        echo "Build directory $BUILD_PATH does not exist"
        return 1
    fi

    cd "$BUILD_PATH"

    rm -f .config
    rm -rf tmp

    if [[ -d logs ]]; then
        rm -rf logs/*
    fi

    if [[ -d feeds ]]; then
        ./scripts/feeds clean
    fi

    mkdir -p tmp
    echo "1" > tmp/.build
}

reset_feeds_conf() {
    cd "$BUILD_PATH"

    # GitHub Actions / 指定 Commit 模式
    if [[ -n "$COMMIT_HASH" && "$COMMIT_HASH" != "none" ]]; then
        echo "使用指定 Commit: $COMMIT_HASH"

        git reset --hard "$COMMIT_HASH"
        git clean -f -d
        return
    fi

    # 本地 / Branch 模式
    echo "同步分支: $REPO_BRANCH"

    git_retry fetch origin "$REPO_BRANCH"
    git reset --hard "origin/$REPO_BRANCH"
    git clean -f -d
}