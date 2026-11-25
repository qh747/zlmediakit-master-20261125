#!/bin/sh
#
# 一次性初始化本仓库的 git remote 约束。可重复执行（幂等）。
#
# 为什么需要这个脚本：
#   .git/config 里的 remote 配置不会随 git clone 分发。新克隆的仓库
#   默认没有 pushurl 保护、没有 hooksPath、pull 方向也指向自己的 fork。
#   本脚本把这些约束重新装回去。
#
# 约束内容见 AGENTS.md 的 "Git remotes" 段。

set -eu

cd "$(git rev-parse --show-toplevel)"

ORIGIN_REMOTE=origin
BASE_REMOTE=upstream

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1 ||
    die "remote '$ORIGIN_REMOTE' 不存在，无法初始化"

# --- 1. upstream 在解析层不可作为推送目标 -------------------------------
# 用 disabled:// 而非裸字符串 DISABLED：后者会被 git 当作相对路径，
# 若工作目录下恰好存在同名仓库就会被静默解析成功，实测可绕过。

if git remote get-url "$BASE_REMOTE" >/dev/null 2>&1; then
    git config "remote.$BASE_REMOTE.pushurl" "disabled://blocked"
    say "已设置 remote.$BASE_REMOTE.pushurl = disabled://blocked"
else
    say "跳过: remote '$BASE_REMOTE' 不存在（只读基线未配置）"
fi

# --- 2. 推只走 origin，拉只走 upstream ----------------------------------

git config remote.pushdefault "$ORIGIN_REMOTE"
say "已设置 remote.pushdefault = $ORIGIN_REMOTE"

if git remote get-url "$BASE_REMOTE" >/dev/null 2>&1; then
    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$current_branch" ]; then
        git config "branch.$current_branch.remote" "$BASE_REMOTE"
        git config "branch.$current_branch.merge" "refs/heads/$current_branch"
        say "已设置 branch.$current_branch.remote = $BASE_REMOTE（裸 pull 拉基线）"
    fi
fi

# --- 3. hook 目录纳入版本控制 ------------------------------------------

git config core.hooksPath githooks
say "已设置 core.hooksPath = githooks"
say ""
say "完成。验证："
say "  git push upstream master   应失败（upstream 只读）"
say "  git fetch                  应显示 From github.com/ZLMediaKit/ZLMediaKit"
