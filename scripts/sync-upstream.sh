#!/bin/bash
#
# sync-upstream.sh
# 从 MetaMask 官方仓库 (upstream) 同步更新到二开分支 (custom-dev)
#
# 用法:
#   ./scripts/sync-upstream.sh              # 默认合并 upstream/main
#   ./scripts/sync-upstream.sh v7.69.0      # 合并指定 tag
#   ./scripts/sync-upstream.sh --rebase     # 使用 rebase 而非 merge

set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
CUSTOM_BRANCH="custom-dev"
MODE="merge"
TARGET=""

for arg in "$@"; do
    case "$arg" in
        --rebase)
            MODE="rebase"
            ;;
        --help|-h)
            echo "用法: $0 [--rebase] [tag/branch]"
            echo ""
            echo "选项:"
            echo "  --rebase    使用 rebase 代替 merge（更线性的历史）"
            echo "  tag/branch  指定要同步的 tag 或分支（默认: main）"
            echo ""
            echo "示例:"
            echo "  $0                  # merge upstream/main"
            echo "  $0 v7.69.0          # merge 指定 tag"
            echo "  $0 --rebase         # rebase onto upstream/main"
            exit 0
            ;;
        *)
            TARGET="$arg"
            ;;
    esac
done

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$CUSTOM_BRANCH" ]; then
    echo "Error: 当前分支为 '$CURRENT_BRANCH'，请切换到 '$CUSTOM_BRANCH'"
    echo "  git checkout $CUSTOM_BRANCH"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: 工作区有未提交的更改，请先 commit 或 stash"
    exit 1
fi

echo "==> 拉取 upstream 最新代码..."
git fetch "$UPSTREAM_REMOTE" --tags

if [ -n "$TARGET" ]; then
    MERGE_REF="$TARGET"
    echo "==> 目标: $TARGET"
else
    MERGE_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    echo "==> 目标: $MERGE_REF"
fi

UPSTREAM_HEAD=$(git rev-parse "$MERGE_REF")
LOCAL_HEAD=$(git rev-parse HEAD)

if [ "$UPSTREAM_HEAD" = "$LOCAL_HEAD" ]; then
    echo "==> 已是最新，无需同步"
    exit 0
fi

BEHIND=$(git rev-list --count HEAD.."$MERGE_REF" 2>/dev/null || echo "?")
AHEAD=$(git rev-list --count "$MERGE_REF"..HEAD 2>/dev/null || echo "?")
echo "==> 当前状态: upstream 领先 $BEHIND 个提交, 二开领先 $AHEAD 个提交"

if [ "$MODE" = "rebase" ]; then
    echo "==> 使用 rebase 模式同步..."
    echo "    如遇冲突请手动解决后运行 git rebase --continue"
    git rebase "$MERGE_REF"
else
    echo "==> 使用 merge 模式同步..."
    echo "    如遇冲突请手动解决后运行 git commit"
    git merge "$MERGE_REF" --no-edit -m "chore: sync upstream $(git log -1 --format='%h %s' $MERGE_REF)"
fi

echo ""
echo "==> 同步完成！"
echo "    建议后续操作:"
echo "    1. yarn install"
echo "    2. yarn setup --no-build-ios"
echo "    3. 测试编译: yarn build:android:main:dev"
