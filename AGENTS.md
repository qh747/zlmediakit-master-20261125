# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, label strings identical to their names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Git remotes

这个仓库有两个 remote，权限不对称。**upstream 只读，origin 只写。**

| remote | 角色 | 允许拉取 | 允许推送 |
| --- | --- | --- | --- |
| `origin` | 自有仓库 `qh747/zlmediakit-master-20261125` | 是 | **是，且是唯一可推送目标** |
| `upstream` | ZLMediaKit 官方基线 `ZLMediaKit/ZLMediaKit` | 是 | **否，永不推送** |

禁止的事，任何情况下都不做：

- `git push upstream ...`，包括 `--force`、`--no-verify`、指定 tag 或分支。
- 向除 `origin` 之外的任何 remote 推送。
- 修改 upstream 仓库的任何内容（issue、PR、label、release 均属此列，除非用户明确要求）。

### 约束的落地位置

约束不是靠这段文字生效的，靠以下机制。新克隆后先跑一次初始化：

```sh
tools/git-baseline/setup.sh
```

它写入四项配置（`.git/config` 不随 clone 分发，所以每台机器都要跑一次）：

| 配置 | 值 | 作用 |
| --- | --- | --- |
| `remote.upstream.pushurl` | `disabled://blocked` | 让 upstream 在 remote 解析阶段就失败 |
| `remote.pushdefault` | `origin` | 裸 `git push` 只走自有仓库 |
| `branch.master.remote` | `upstream` | 裸 `git pull` / `git fetch` 作用于基线 |
| `core.hooksPath` | `githooks` | 让 pre-push 钩子随仓库分发 |

`githooks/pre-push` 是第二道防线，它在建立网络连接前拒绝非 `origin` 的推送。

**为什么 pushurl 不能省。** `git push --no-verify` 会跳过 pre-push 钩子，这是 git 的既定行为，无法从钩子内部阻止。只有 `disabled://blocked` 不可绕过。

**为什么不能写成裸字符串 `DISABLED`。** git 会把它当相对路径解析，若工作目录下存在同名仓库，推送会被静默放行。实测确认过。必须保留 `disabled://` 协议前缀。

### 同步基线

基线是 `upstream/master`。同步用脚本，不要手工 `merge`/`rebase`：

```sh
tools/git-baseline/sync-baseline.sh --check   # 只预检，不改任何东西
tools/git-baseline/sync-baseline.sh           # 预检 + 快进
```

脚本行为：

- 同步前用 `git merge-tree --write-tree` 做冲突预检，**不碰工作区与索引**。
- 有冲突就停下并列出冲突文件，不替人解决。
- 本地有自有提交、与基线分叉时停下，**不替人在 rebase 与 merge 之间做选择**。
- 同步后报告子模块 SHA 与 tag 变化。

`.gitmodules` 指向 gitee，`.gitmodules_github` 是 github 镜像。gitee 不可达时用后者替换，再 `git submodule sync --recursive`。

### 推送前

- 确认 `git remote -v` 里 `origin` 是你自己的仓库。
- 推 `origin` 会触发 `ZLMediaKit` 移植来的全套 CI。`docker.yml` 与 `docker_py.yml` 依赖 `secrets.DOCKER_IO_SECRET`，fork 上必然失败，且不应配置该 secret（镜像会推到官方 `zlmediakit/zlmediakit`）。

