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

它写入以下配置（`.git/config` 不随 clone 分发，所以每台机器都要跑一次）：

| 配置 | 值 | 作用 |
| --- | --- | --- |
| `remote.upstream.pushurl` | `disabled://blocked` | 让 upstream 在 remote 解析阶段就失败 |
| `remote.pushdefault` | `origin` | 裸 `git push` 只走自有仓库 |
| `branch.master.remote` | `origin` | master 的裸 `git pull` 只拉自己的 fork |
| `branch.master.pushRemote` | `disabled://blocked` | master 上的裸 `git push` 直接失败 |
| `core.hooksPath` | `githooks` | 让 pre-push 钩子随仓库分发 |

`githooks/pre-push` 是第二道防线，它在建立网络连接前拒绝非 `origin` 的推送，
以及不符合分支与 tag 规则的 ref。

**为什么 pushurl 不能省。** `git push --no-verify` 会跳过 pre-push 钩子，这是 git 的既定行为，无法从钩子内部阻止。只有 `disabled://blocked` 不可绕过。

**为什么不能写成裸字符串 `DISABLED`。** git 会把它当相对路径解析，若工作目录下存在同名仓库，推送会被静默放行。实测确认过。必须保留 `disabled://` 协议前缀。

### 分支

三个分支，角色互斥。用错分支会被脚本或钩子当场拒绝。

| 分支 | 角色 | 允许的操作 |
| --- | --- | --- |
| `master` | 对外发布分支 | 只接受已验证分支的合并。不直接提交，不直接推送 |
| `feature/develop` | 日常开发 | 直接提交、推送。CI 只跑 `linux` |
| `feature/merge_upstream` | 基线合并的验证场 | 只用于合入 `upstream/master`，不写业务代码 |

**`master` 的裸 `git pull` 拉不到上游。** `branch.master.remote` 指向 `origin`，
所以裸 `git pull` 只同步你自己的 fork。旧配置指向 `upstream`，一次裸 pull 就把
上游快进进了发布分支，绕过全部验证。实测确认改配置后上游的新文件不再出现在
工作区。

#### 合并基线的完整流程

```sh
# 1. 从 master 切验证分支
git switch master && git pull
git switch -c feature/merge_upstream --track origin/master

# 2. 同步基线。脚本会拒绝在 master 或 develop 上运行
tools/git-baseline/sync-baseline.sh --check
tools/git-baseline/sync-baseline.sh

# 3. 编译验证，见下方「验证判据」

# 4. 验证通过后合入 master
git switch master
git merge --no-ff feature/merge_upstream

# 5. 回流 develop，避免下次合并重复解决同一批冲突
git switch feature/develop
git merge feature/merge_upstream
```

`feature/merge_upstream` 从 `master` 切出，不从业 `develop` 切。验证对象只有
上游的改动，diff 干净。从业 `develop` 切会把未验证的代码混进验证对象。

从 `master` 切新分支不继承追踪配置。实测确认新分支没有 upstream，`--track`
必须显式写。

#### master 的三层防线

| 层 | 机制 | 拦什么 | `--no-verify` 下 |
| --- | --- | --- | --- |
| 第一层 | `branch.master.pushRemote=disabled://blocked` | 裸 `git push` | 仍生效 |
| 第二层 | `githooks/pre-push` 检查 stdin 的 `refs/heads/master` | 显式 `git push origin master` | 失效 |
| 第三层 | GitHub 分支保护 | 任何机器上的任何推送 | 仍生效 |

第一层与第二层互补。实测：只配 `pushRemote` 时，显式 `git push origin master`
照样成功；加上钩子后该命令被拒。`--no-verify` 同时击穿第一层的显式命令场景和
第二层。

第三层是唯一能兜住 `--no-verify` 的机制。仓库是公开仓库，分支保护免费可用。

发版需要覆盖 master 保护时，用一次性配置覆盖，不改 `.git/config`：

```sh
git -c branch.master.pushRemote=origin push origin master
```

#### 验证判据

本轮标准是编译通过。在仓库根目录执行：

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

前置条件是子模块已检出：

```sh
git submodule update --init --recursive
```

`.gitmodules` 指向 gitee，不可达时先换源：

```sh
cp .gitmodules_github .gitmodules && git submodule sync --recursive
```

判定标准有两条：`cmake --build` 退出码为 0，且 `build/release/linux/Release/MediaServer`
存在。只看退出码不够，产物缺失也算失败。

#### CI 触发矩阵

推 `feature/develop` 只跑 `linux`。其余平台在 PR 时跑。矩阵由
`.github/workflows/*.yml` 的 `on.push.branches` 直接决定。

| workflow | master | feature/develop | feature/merge_upstream | release/* |
| --- | --- | --- | --- | --- |
| `linux` | 触发 | **触发** | 触发 | 触发 |
| `android` `codeql` `linux_arm64` `linux_py` `macos` `macos_py` `windows` `windows_py` | 触发 | 跳过 | 触发 | 触发 |
| `docker` `docker_py` | 跳过 | 跳过 | 跳过 | 触发 |
| `style` | 跳过 | 跳过 | 跳过 | 跳过 |

`docker` 与 `docker_py` 排除 `feature/*` 下的两个长期分支。它们命中
`feature/*` 时会以 `zlmediakit/zlmediakit` 名义往官方 Docker Hub 推送，fork
上没有 `secrets.DOCKER_IO_SECRET`，必然失败。

`style` 只在 `pull_request` 上跑。PR 是所有平台的完整门禁。

### 同步基线

基线是 `upstream/master`。同步用脚本，不要手工 `merge`/`rebase`。脚本只在
`feature/merge_upstream` 上运行：

```sh
tools/git-baseline/sync-baseline.sh --check   # 只预检，不改任何东西
tools/git-baseline/sync-baseline.sh           # 预检 + merge
```

脚本行为：

- 当前分支不是 `feature/merge_upstream` 就直接退出，并打印正确流程。
- 同步前用 `git merge-tree --write-tree` 做冲突预检，**不碰工作区与索引**。
- 有冲突就停下并列出冲突文件，不替人解决。
- 分叉时默认 `merge`（`--rebase` 可改）。理由：自有提交是叠加在基线之上的功能，不是要上游接纳的补丁。merge 保留"哪些是我们的"这个信息，且不重写自有提交的 SHA，推 origin 后不需要 force push。
- 无分叉时用 `--ff-only` 快进。
- 同步后报告子模块 SHA 与 tag 变化。

`.gitmodules` 指向 gitee，`.gitmodules_github` 是 github 镜像。gitee 不可达时用后者替换，再 `git submodule sync --recursive`。

### tag

命名格式 `RELEASE-V<主>.<次>.<修>-<YYYYMMDD>`，示例 `RELEASE-V1.0.0-20261126`。

| 项 | 规则 |
| --- | --- |
| 正则 | `^RELEASE-V[1-9][0-9]*\.[0-9]+\.[0-9]+-[0-9]{8}$` |
| 大小写 | 全大写。`release-` 开头的会被拒 |
| 版本号 | 三段，不允许前导零（`V01.0.0` 拒绝），不允许缺段（`V1.0` 拒绝） |
| 日期 | 发版日，不是 commit 日期。必须是真实存在的日期 |
| 类型 | annotated。lightweight 的 `creatordate` 等于 commit 时间，写不出打标日 |

`githooks/pre-push` 在推送时校验格式和日期。日期用纯 shell 校验，不用
`date -d`，那是 GNU 专有语法，macOS 的 BSD date 会直接报错。

#### 创建

只在 `master` 上打，`-m` 里写所基于的基线 SHA：

```sh
git switch master
git tag -a RELEASE-V1.1.0-20261201 -m "基于 ZLMediaKit 上游 master <sha>"
git push origin RELEASE-V1.1.0-20261201
```

#### V1.0.0 是唯一的历史特例

`RELEASE-V1.0.0-20261126` 指向 `5db25916`，也就是 `upstream/master`，不指向
本地 `master`。当时二者源码零差异，`git diff` 里 0 个 `.cpp` / `.h` 文件，所以
编出的二进制相同。

`V1.1.0` 起必须打在 `master` 上。若照抄 V1.0.0 的做法指向上游，那个 tag 会
不包含本项目的工作。

这条特例的代价：检出 `5db25916` 的人拿不到 `githooks/` 与 `AGENTS.md`。git 对
不存在的 `core.hooksPath` 静默通过，提交退出码仍是 0，所以那个工作区没有任何
推送防护。只在该 tag 上做只读构建，不要在它的工作区里推送。

#### 重命名

旧 tag 已在远端时，四步。`git push --tags` 不会删除远端旧 tag，实测确认。

```sh
# 1. 在目标 commit 上建新 tag。写死 SHA，不要写 master
git tag -a RELEASE-V1.0.0-20261126 5db25916 \
  -m "基于 ZLMediaKit 上游 master 5db25916 的构建快照"

# 2. 删本地旧 tag
git tag -d v20261125

# 3. 推新 tag。这一步会触发 9 个 workflow
git push origin RELEASE-V1.0.0-20261126

# 4. 删远端旧 tag。必须显式 refspec
git push origin :refs/tags/v20261125
```

第 4 步的 `(delete)` 前缀会被钩子跳过。若钩子没跳过它，旧 tag 永远删不掉。

回滚按相反顺序做一遍：删新 tag（本地与远端），在 `5db25916` 上重建旧的
annotated tag，推回远端。

#### 排序查询

默认排序是字典序，会把 `V1.10.0` 排到 `V1.2.0` 前面。查最新版本用：

```sh
git tag --list --sort=version:refname | grep '^RELEASE-V'
```

#### 已知绕过方式

| 绕过 | 后果 | 防线 |
| --- | --- | --- |
| `git push --no-verify` | 跳过 `githooks/pre-push`，畸形 tag 能推上去 | 只能靠服务端 tag ruleset |
| GitHub 分支保护 | **不覆盖 tag**，是独立特性 | 需单独配 tag ruleset |

同一天发第二个修订会撞名，报 `already exists`。格式无法表达同日第二版，需要升
PATCH 号，或者显式 `-f` 覆盖并说明原因。

### 推送前

- 确认 `git remote -v` 里 `origin` 是你自己的仓库。
- 推 `feature/develop` 只跑 `linux`。全平台门禁在 PR 上。
- `docker.yml` 与 `docker_py.yml` 已排除 `master`、`feature/develop`、
  `feature/merge_upstream`。这三个分支推送不会再触发必然失败的 Docker Hub
  推送，不要把它们加回去。

