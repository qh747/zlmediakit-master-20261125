#!/bin/sh
#
# 把本地 ZLMediaKit 基线同步到 upstream/master 最新提交。
#
# 设计要点：
#   - 同步前做冲突预检（git merge-tree --write-tree），不碰工作区与索引。
#   - 预检有冲突就停下并列出冲突文件，不替用户解决冲突。
#   - 同步完成后报告子模块 SHA 变化与 tag 变化，由用户决定是否跟。
#   - 幂等：重复执行不产生额外状态。
#
# 用法：
#   tools/git-baseline/sync-baseline.sh            预检 + 同步（merge 策略，见下文）
#   tools/git-baseline/sync-baseline.sh --check    只预检，不改任何东西
#
# 分支约束：
#   本脚本只在 feature/merge_upstream 上运行。基线合并必须先在这个分支上
#   编译验证，再合入 master。在 master 上直接同步会绕过验证，在 develop 上
#   直接同步会把未验证的基线代码混进日常开发分支。两条都不允许。
#
# 策略说明：
#   分叉时默认 merge。自有提交是叠加在基线之上的功能，不是要上游接纳的
#   补丁。merge 保留"哪些是我们的"这个信息，且不重写自有提交的 SHA，推
#   origin 后不需要 force push。--rebase 可改。

set -eu

cd "$(git rev-parse --show-toplevel)"

BASE_REMOTE=upstream
BASE_REF="$BASE_REMOTE/master"
MERGE_BRANCH=feature/merge_upstream
CHECK_ONLY=0
STRATEGY=merge

case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    --rebase) STRATEGY=rebase ;;
    --merge) STRATEGY=merge ;;
    "")
        ;;
    *)
        echo "用法: $0 [--check] [--merge|--rebase]" >&2
        exit 2
        ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- 1. 前置检查 ---------------------------------------------------------

git remote get-url "$BASE_REMOTE" >/dev/null 2>&1 ||
    die "remote '$BASE_REMOTE' 不存在。请先 git remote add upstream <url>"

current_branch=$(git symbolic-ref --quiet --short HEAD) ||
    die "当前处于分离 HEAD 状态，拒绝自动同步"

# 基线合并只能在 feature/merge_upstream 上做。在 master 上做会绕过编译验证，
# 在 develop 上做会把未验证的基线代码混进日常开发分支。
if [ "$current_branch" != "$MERGE_BRANCH" ]; then
    {
        echo "error: 当前分支是 '$current_branch'，基线同步只能在 $MERGE_BRANCH 上运行。"
        echo ""
        echo "流程："
        echo "  git switch -c $MERGE_BRANCH --track origin/master"
        echo "  tools/git-baseline/sync-baseline.sh"
        echo "  编译验证通过后："
        echo "  git switch master && git merge --no-ff $MERGE_BRANCH"
        echo "  git switch feature/develop && git merge $MERGE_BRANCH"
    } >&2
    exit 2
fi

if [ -n "$(git status --porcelain)" ]; then
    die "工作区或索引有未提交改动。请先提交或 stash 后再同步。"
fi

# --- 2. 拉取基线 ---------------------------------------------------------

say "==> 拉取 $BASE_REF"
git fetch "$BASE_REMOTE" --prune --tags

new_ref=$(git rev-parse "$BASE_REF")
say "    基线最新提交: $new_ref $(git log -1 --format='%s' "$new_ref")"

ahead=$(git rev-list --count "$BASE_REF"..HEAD)
behind=$(git rev-list --count "HEAD..$BASE_REF")

say "    本地领先 $BASE_REF: $ahead 个提交"
say "    本地落后 $BASE_REF: $behind 个提交"

if [ "$behind" -eq 0 ]; then
    if [ "$ahead" -eq 0 ]; then
        say "==> 已是最新，无需同步"
    else
        say "==> 本地已包含基线全部提交，另有 $ahead 个自有提交，无需同步"
    fi
    exit 0
fi

# --- 3. 冲突预检，不污染工作区 -------------------------------------------

say "==> 冲突预检 (git merge-tree --write-tree)"
if ! merge_out=$(git merge-tree --write-tree "$BASE_REF" HEAD 2>&1); then
    say ""
    say "预检发现冲突，已停止，未改动任何文件。"
    say ""
    say "$merge_out" | grep -E '^(CONFLICT|Auto-merging)' | sed 's/^/    /' || true
    say ""
    # merge-tree 的机器可读段: "100644 <oid> <stage>\t<path>"，stage 为 1/2/3 表示冲突
    conflict_files=$(printf '%s\n' "$merge_out" |
        awk -F'\t' 'NF >= 2 && $1 ~ /^[0-7]{6} / { print $2 }' | sort -u)
    if [ -n "$conflict_files" ]; then
        say "冲突文件:"
        printf '%s\n' "$conflict_files" | sed 's/^/    - /'
    fi
    say ""
    say "请人工处理后重跑本脚本。"
    exit 1
fi
say "    预检通过，无冲突"

if [ "$CHECK_ONLY" -eq 1 ]; then
    say "==> --check 模式，停止于预检"
    exit 0
fi

# --- 4. 记录同步前的状态 -------------------------------------------------
#
# 快照必须在合并之前取，否则 diff 永远是空的。
old_ref=$(git rev-parse HEAD)

# submodule status 的首列可能带 - (未初始化) 或 + (SHA 不匹配) 前缀，
# 直接比较会让状态翻转产生假阳性，因此统一剥离后再比较。
submodule_snapshot() {
    git submodule status --recursive 2>/dev/null |
        awk '{ print $1, $2 }' |
        sed 's/^[+-]//' |
        sort
}
old_subs=$(submodule_snapshot)
old_tags=$(git tag --points-at HEAD | sort)

# --- 5. 分叉处理 ---------------------------------------------------------
#
# 本仓库的策略是 merge（已定），理由：自有提交是叠加在基线之上的功能，
# 不是要上游接纳的补丁。merge 保留"哪些是我们的"这个真实信息，且不重写
# 自有提交的 SHA，推 origin 后无需 force push。
# rebase 会把自有提交全部重放到基线末尾、SHA 全变，需要 force push。
# 需要改用 rebase 时加 --rebase。

if [ "$ahead" -ne 0 ]; then
    say ""
    say "本地有 $ahead 个自有提交，与基线分叉。"
    if [ "$STRATEGY" = "rebase" ]; then
        say "==> 按 rebase 策略把自有提交重放到 $BASE_REF"
        git rebase "$BASE_REF"
    else
        say "==> 按 merge 策略合并 $BASE_REF"
        git merge --no-edit "$BASE_REF"
    fi
else
    say "==> 快进到 $BASE_REF"
    git merge --ff-only "$BASE_REF"
fi

# --- 6. 报告变化 ---------------------------------------------------------

say ""
say "==> 同步完成"
say "    $(git rev-parse --short "$old_ref") -> $(git rev-parse --short HEAD)"

new_subs=$(submodule_snapshot)
if [ "$old_subs" = "$new_subs" ]; then
    say "    子模块无变化"
else
    say ""
    say "    子模块 SHA 有变化，需要同步子模块内容:"
    say ""
    printf '%s\n' "$old_subs" > /tmp/.sync-baseline-old-subs.$$
    printf '%s\n' "$new_subs" > /tmp/.sync-baseline-new-subs.$$
    diff -u /tmp/.sync-baseline-old-subs.$$ /tmp/.sync-baseline-new-subs.$$ |
        grep -E '^[-+][^-+]' | sed 's/^/      /' || true
    rm -f /tmp/.sync-baseline-old-subs.$$ /tmp/.sync-baseline-new-subs.$$
    say ""
    say "    子模块 .gitmodules 指向 gitee。若 gitee 不可达，改用 github 源:"
    say "      cp .gitmodules_github .gitmodules && git submodule sync --recursive"
    say "      git submodule update --init --recursive"
    say ""
    say "    否则直接:"
    say "      git submodule update --init --recursive"
fi

new_tags=$(git tag --points-at HEAD | sort)
if [ "$old_tags" != "$new_tags" ]; then
    say ""
    say "    当前 HEAD 上的 tag 变化:"
    say "      旧: ${old_tags:-<无>}"
    say "      新: ${new_tags:-<无>}"
fi

say ""
say "刷新后的子模块指针仍需提交到 origin 才会生效。"
