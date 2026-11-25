#!/bin/sh
#
# 一次性初始化本仓库的分支与 remote 约束。可重复执行（幂等）。
#
# 为什么需要这个脚本：
#   .git/config 里的 remote 与 branch 配置不会随 git clone 分发。新克隆的
#   仓库默认没有 pushurl 保护、没有 hooksPath、master 的 pull 方向也指向
#   了自己的 fork。本脚本把这些约束重新装回去。
#
# 约束内容见 AGENTS.md 的「分支」段。

set -eu

cd "$(git rev-parse --show-toplevel)"

ORIGIN_REMOTE=origin
BASE_REMOTE=upstream
RELEASE_BRANCH=master
DEV_BRANCH=feature/develop
MERGE_BRANCH=feature/merge_upstream

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1 ||
    die "remote '$ORIGIN_REMOTE' 不存在，无法初始化"

has_base=0
if git remote get-url "$BASE_REMOTE" >/dev/null 2>&1; then
    has_base=1
fi

# --- 1. upstream 在解析层不可作为推送目标 -------------------------------
# 用 disabled:// 而非裸字符串 DISABLED：后者会被 git 当作相对路径，
# 若工作目录下恰好存在同名仓库就会被静默解析成功，实测可绕过。

if [ "$has_base" -eq 1 ]; then
    git config "remote.$BASE_REMOTE.pushurl" "disabled://blocked"
    say "已设置 remote.$BASE_REMOTE.pushurl = disabled://blocked"
else
    say "跳过: remote '$BASE_REMOTE' 不存在（只读基线未配置）"
fi

# --- 2. 推只走 origin ----------------------------------------------------

git config remote.pushdefault "$ORIGIN_REMOTE"
say "已设置 remote.pushdefault = $ORIGIN_REMOTE"

# --- 3. master 的拉取方向指向自己的 fork，不指向基线 --------------------
#
# 这里曾经写成 branch.master.remote=upstream、merge=refs/heads/master，
# 结果是 master 上的裸 git pull 直接把 upstream 快进进发布分支，绕过所有
# 验证。实测确认过。现在 master 只跟踪 origin/master，拉基线必须走
# tools/git-baseline/sync-baseline.sh 或显式 git fetch upstream。

git config "branch.$RELEASE_BRANCH.remote" "$ORIGIN_REMOTE"
git config "branch.$RELEASE_BRANCH.merge" "refs/heads/$RELEASE_BRANCH"
say "已设置 branch.$RELEASE_BRANCH.remote = $ORIGIN_REMOTE（裸 pull 不再吸收上游）"

# --- 4. master 上的裸 push 直接失败 -------------------------------------
#
# pushRemote 只作用于裸 git push。显式 git push origin master 仍会走
# pre-push hook 的第二道检查，两层互补。实测确认显式命令能绕过这一项。

git config "branch.$RELEASE_BRANCH.pushRemote" "disabled://blocked"
say "已设置 branch.$RELEASE_BRANCH.pushRemote = disabled://blocked"

# --- 5. 删掉所有非 master 分支上的坏追踪 -------------------------------
#
# 旧版本把 branch.<当前分支>.merge 写成 refs/heads/<当前分支>。在
# feature/develop 上跑一次之后，裸 git pull 会报
# "no such ref was fetched"。这里统一清理，让每个分支只跟踪远端同名分支。

current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -n "$current_branch" ] && [ "$current_branch" != "$RELEASE_BRANCH" ]; then
    if git config --get "branch.$current_branch.remote" >/dev/null 2>&1; then
        remote_value=$(git config --get "branch.$current_branch.remote")
        if [ "$remote_value" = "$BASE_REMOTE" ]; then
            git config --unset "branch.$current_branch.remote" || true
            git config --unset "branch.$current_branch.merge" || true
            say "已清理 branch.$current_branch 指向 $BASE_REMOTE 的坏追踪"
        fi
    fi
fi

# --- 6. hook 目录纳入版本控制 ------------------------------------------

git config core.hooksPath githooks
say "已设置 core.hooksPath = githooks"

# --- 7. 分支存在性提示 --------------------------------------------------

say ""
for b in "$RELEASE_BRANCH" "$DEV_BRANCH" "$MERGE_BRANCH"; do
    if git rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
        say "分支 $b 存在"
    else
        say "分支 $b 不存在。日常开发前先创建: git switch -c $b --track origin/$b"
    fi
done

say ""
say "完成。验证:"
say "  在 $RELEASE_BRANCH 上裸 git push          应失败（pushRemote）"
say "  git push origin $RELEASE_BRANCH          应失败（pre-push hook）"
say "  git push origin $DEV_BRANCH              应放行"
say "  在 $RELEASE_BRANCH 上裸 git pull         不应出现 upstream 的新文件"
