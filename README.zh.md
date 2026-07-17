# Perstate — Permanent State for Your Agents and Yourself

> perstate = **per**sonality + **state**
>
> 基于 git 原生知识图谱的个人与智能体持久 state。

---

## 前置条件

- **git** — 所有操作基于 git
- **SSH key**（推荐）— state 包含隐私知识，推荐走 SSH 协议接入仓库
- **标准 shell 环境** — `ls`、`grep`、`find`、`cat`、`mkdir`、`echo`、`rm`、`sed`

---

## 安装

```bash
npx skills add graphwisdom/perstate
```

或手动克隆：

```bash
git clone git@github.com:graphwisdom/perstate.git ~/.agents/skills/perstate
```

---

## 快速开始

```bash
# 1. 初始化（首次需指定仓库地址，默认分支 main）
/perstate init --repo git@github.com:<user>/<repo>.git

# 2. 查看状态（默认操作，无副作用）
/perstate

# 3. 写入知识（扫描对话上下文自动提取洞察）
/perstate save

# 4. 召回记忆
/perstate search <关键词>

# 5. 可视化
/perstate view

# 6. Fork 分支（从当前记忆复制出新 Agent 的 state）
/perstate fork agent-a

# 7. 切回个人记忆
/perstate switch main

# 8. 清理过期数据（预览后确认执行）
/perstate prune 30d
```

---

## 设计哲学

1. **State 身份 = repo + branch** — 一个仓库用分支隔离多个 Agent 的 state，`main` 是个人默认分支。不需要为每个 Agent 创建独立仓库，分支即身份，天然隔离，可 merge / cherry-pick 交流知识。
2. **文件系统即图** — 实体是目录，关系是文件。`ls` 就是图查询，`grep` 就是全文搜索，`find` 就是反向遍历。无需图数据库，无需索引文件，无需 JSON 中间层。一事一文件，单一事实来源。
3. **知识加工而非简单存储** — 写入不是 append，而是去重、消歧、合并。每次写入先查询已有图谱，决定新建还是合并，避免知识碎片化。这是 perstate 与日记式记忆的根本区别。
4. **git 即时序引擎** — `valid_until` 做软删除，`git log --follow` 做完整溯源，`git diff` 做变更审阅。时间维度交给 git，不另建版本管理。
5. **零依赖、即插即用** — 纯 shell + git，无运行时、无守护进程、无外部工具。任何 Agent 接入即具备远程记忆、知识备份和召回能力。全部 markdown + YAML frontmatter，人类可读，git 友好。
6. **开放 schema** — YAML frontmatter 增量演进，新字段不破坏旧数据。Ontology 是文档不是约束，未知字段保留不拒绝。
7. **按需加载** — 图 → 实体 → 关系类型 → 关系。只读需要的部分，不需要加载全图。

---

## 分支隔离

一个仓库用分支承载多个 Agent 的持久态，`main` 是个人默认分支：

```
<repo>.git
├── branch: main         ← 个人 personality 与知识
├── branch: agent-a      ← agent-a 智能体的 state
├── branch: agent-b      ← agent-b 智能体的 state
└── branch: agent-c      ← agent-c 智能体的 state
```

分支间互不干扰，可通过 fork / merge / cherry-pick 交流知识。

### 并发与 worktree

每个分支拥有独立的 worktree，由 `perstate-prepare.sh` 和 `perstate-init.sh` 自动管理：

- **不同分支**：真并行，各 worktree 独立，零冲突。
- **同一分支**：git 拒绝在同一分支创建第二个 worktree（`already checked out`），强制串行化。Agent B 等待 Agent A 释放后再操作。
- **崩溃恢复**：`git worktree prune` 清理残留 worktree，脚本每次运行时自动检测。

Worktree 目录约定：

```
~/.perstate/
  <repo-name>.git/                  ← bare repo（git 对象存储，多 repo 共存）
  worktrees/
    <repo-name>/
      <branch>/                      ← worktree（长期持有，prune 清过期）
```

- **远程仓库**：`git clone --bare` 到 `~/.perstate/<repo-name>.git/`，worktree 在 `~/.perstate/worktrees/<repo-name>/<branch>/`。写入后自动 `git push`，读取前自动 `git pull`。推荐 SSH。
- **本地仓库**：同样 `git clone --bare` 从本地路径，origin 指向本地目录。push/pull 走本地文件系统，瞬时完成。如果不是 git 仓库，自动 `git init`。

---

## 配置

配置在本地机器上（`~/.perstate/config.yml`），不在知识仓库内。

```yaml
default_repo: git@github.com:<user>/<repo>.git
default_branch: main
sessions:
  abc123:
    branch: agent-a
```

| 字段 | 用途 |
|------|------|
| `default_repo` | 全局默认仓库，安装时配置 |
| `default_branch` | 全局默认分支，默认 `main`，可通过 init `--branch` 修改 |
| `sessions` | 会话级 branch 绑定，自动管理 |

- Worktree 路径不存储——按约定发现：`~/.perstate/worktrees/<repo-name>/<branch>/`
- bare repo 路径：`~/.perstate/<repo-name>.git/`（多 repo 共存，切换不清理）
- 没有 `agent-id` 字段——身份就是 `branch`（repo 固定为 default_repo）

### Agent 状态绑定

通过系统提示词可以让 Agent 跳过确认，自动完成首次配置：

```
perstate repo: <repo-url>       # 仅 config 不存在时生效，跳过 init 确认
perstate branch: <branch-name>  # 仅 session 未绑定时生效，跳过会话绑定确认
```

> **本地配置优先**：config 已存在则忽略 `perstate repo:`，session 已绑定则忽略 `perstate branch:`。系统提示词只在首次配置时起作用，不覆盖已有配置。

### 配置读取

```bash
DEFAULT_REPO=$(grep "^default_repo:" ~/.perstate/config.yml | sed 's/^[^:]*: *//')
DEFAULT_BRANCH=$(grep "^default_branch:" ~/.perstate/config.yml | sed 's/^[^:]*: *//')
SESSION_BRANCH=$(grep -A1 "^  <session-id>:" ~/.perstate/config.yml | grep "branch:" | sed 's/^[^:]*: *//')
```

---

## 脚本说明

所有脚本位于 skill 安装目录的 `scripts/` 下。

| 脚本 | 用途 | 关键参数 |
|------|------|----------|
| `perstate-init.sh` | 初始化或更新配置：环境检查 → 配置写入 → 仓库 clone → worktree 创建 → 初始结构创建 → 提交推送 | `[--repo <url>]` `[--branch <branch>]` `[--yes]`（首次需 --repo） |
| `perstate-prepare.sh` | 写入前准备：会话绑定查找 → worktree 创建/复用 → 拉取最新 → 写入 session 绑定 | `--session-id <id>` `[--repo <url>]` `[--branch <branch>]` |
| `perstate-commit.sh` | 写入后提交：git add + commit + push | `--message "<summary>"` `--session-id <id>` |
| `perstate-info.sh` | 状态检查（`--status`）或记忆统计（默认）：配置、会话、实体数、关系数、最近提交 | `--status` `[--session-id <id>]` |
| `perstate-view.sh` | 浏览器渲染：生成交互式 HTML 图谱（vis-network），自动打开浏览器 | `--session-id <id>` |
| `perstate-fork.sh` | 基于当前分支 fork 新分支并重新绑定 | `--name <new-branch>` `--session-id <id>` |
| `perstate-switch.sh` | 切换当前会话绑定的分支（原地改 config，调 prepare 同步 worktree） | `--name <branch>` `--session-id <id>` |
| `perstate-prune.sh` | 清理过期会话绑定、worktree 和无效分支（先预览再确认执行） | `[<days>d]` `[--execute]` |

---

## 可扩展性

当前设计本身就有天然的扩展点，无需架构变更：

- **Schema 开放**：新增实体类型、关系类型、frontmatter 字段——直接写入 `ontology.md` 即可，无需迁移已有数据
- **命令可扩展**：`/perstate` 前缀体系，`scripts/` 目录可增加新脚本（如 `/perstate search`、`/perstate export`）
- **存储标准**：git 仓库 + markdown，任何能读 git 的工具都能消费知识图谱——图可视化、全文搜索、静态站点生成
- **多 Agent 协作**：branch 隔离 + fork 复制 + merge/cherry-pick 共享，Agent 间知识交流无需额外机制

---

## 附录：Shell 命令速查

| 操作 | 命令 |
|------|------|
| 列出所有实体 | `ls entities/` |
| 实体详情 | `cat entities/<id>/entity.md` |
| 列出出关系类型 | `ls entities/<id>/` |
| 列出某类型的关系 | `ls entities/<id>/depends-on/` |
| 读取一条关系 | `cat entities/<id>/depends-on/<to>.md` |
| 关键词搜索 | `grep -rl "keyword" entities/` |
| 反向查找（→X） | `find entities/ -name "X.md"` |
| 最近变更 | `ls -lt entities/<id>/` |
| Git 历史 | `git log --follow entities/<id>/entity.md` |
| 只看有效关系 | `grep -rl "valid_until: null" entities/<id>/` |
| 新建实体 | `mkdir -p entities/<id>` + 写 entity.md |
| 新建关系 | `mkdir -p entities/<from>/<type>` + 写 `<to>.md` |
| 删除关系（硬） | `rm entities/<from>/<type>/<to>.md` |
| 删除实体 | `rm -rf entities/<id>/` + `find entities/ -name "<id>.md" -delete` |
| 创建 worktree | `git worktree add <repo-dir>/<branch> <branch>` |
| 移除 worktree | `git worktree remove <repo-dir>/<branch>` |
| 清理过期 worktree | `git worktree prune` |
| 提交并推送 | `scripts/perstate-commit.sh --message "..." --session-id <id>` |

---

## 许可证

[Apache License 2.0](LICENSE)
