---
name: perstate
description: >-
  git 原生的远程知识图谱，为智能体和个人提供持久 state。
  /perstate 查看状态，/perstate save 写入沉淀，/perstate search 召回搜索，/perstate fork 复制分支，/perstate switch 切换分支，/perstate info 统计，/perstate view 可视化，/perstate prune 清理。
  触发：用户说"沉淀""记住""回忆""recall""memory""之前""你之前说过"或输入 /perstate。
  自动提取洞察，去重合并，多跳查询，图谱可视化。
---

## 命令体系

所有操作统一为 `/perstate` 前缀。脚本位于 skill 安装目录的 `scripts/` 下。

> Agent 收到 skill 内容 + args 后，将 args 映射到下表对应命令执行。

| 命令 | 用途 | 脚本调用 |
|------|------|----------|
| `/perstate` | 状态检查（无副作用，查看配置完整性和会话绑定，引导 init） | `scripts/perstate-info.sh --status --session-id <id>` |
| `/perstate init` | 初始化配置（Agent 会引导用户提供仓库地址和分支名） | `scripts/perstate-init.sh [--repo <url>] [--branch <branch>]` |
| `/perstate save [内容]` | 写入记忆（扫描上下文或按指定内容写入。创建/更新/删除由 Agent 根据语义判断） | `scripts/perstate-prepare.sh --session-id <id>` → 知识加工 → `scripts/perstate-commit.sh --session-id <id>` |
| `/perstate search <关键词>` | 召回记忆（单点、多跳、子图、自然语言） | `scripts/perstate-search.sh --session-id <id> <关键词>`（fast path：`--read` 模式跳过同步，grep -RErIn 批量扫描） |
| `/perstate info` | 记忆统计（实体数、关系数、最近提交） | `scripts/perstate-info.sh --session-id <id>` |
| `/perstate view` | 在浏览器渲染记忆图谱 | `scripts/perstate-view.sh --session-id <id>` |
| `/perstate fork <name>` | 基于当前分支 fork 新分支并重新绑定 | `scripts/perstate-fork.sh --name <name> --session-id <id>` |
| `/perstate switch <branch>` | 切换当前会话绑定的分支 | `scripts/perstate-switch.sh --name <branch> --session-id <id>` |
| `/perstate prune [Nd]` | 清理过期会话绑定、worktree 和无效分支（先预览再确认执行） | `scripts/perstate-prune.sh <days>d [--session-id <id>] [--execute]` |

> Agent 调用脚本时必须传 `--session-id <id>`，**不要用 `--worktree` 绕过会话绑定**。未绑定的会话必须先走会话绑定流程。session ID 来源：CC 用会话 UUID，Kimi Code 用 session 路径 ID，其他平台用会话标识或 `date +%s`。不要用 `$$` 或 `basename "$PWD"` 构造。

---

## 初始化（`/perstate init`）

用户执行 `/perstate init` 时的流程：

1. **Agent 分步收集 repo + branch**（不能跳过）：
   - 如果 config 已存在 → 读取 `default_repo` 和 `default_branch`，用结构化交互确认是否保持不变或修改
   - 如果 config 不存在 → 用 AskUserQuestion 收集（一次调用，两个问题）：
     - **仓库地址**：选项 SSH 远程仓库（推荐）/ 本地路径 / HTTPS 远程仓库（不推荐）+ Other 自定义输入实际地址
     - **分支名**：选项 `main`（默认）/ 自定义 + Other 自定义输入
     - 用户选 SSH/本地/HTTPS 后通过 Other 输入具体地址；选 main 直接确认
2. **Agent 执行脚本**（传 `--yes` 跳过脚本内的交互确认，因为 Agent 已在步骤 1 确认过）：
   ```bash
   scripts/perstate-init.sh --repo <url> --branch <branch> --yes
   ```
   首次需 `--repo`；后续可省略（从 config 读取默认值）。
3. 脚本自动完成：检查 git → 检查 repo 协议（非 SSH 给安全警告）→ 写入配置 → clone 仓库 → 创建 worktree → 创建初始结构 → 提交推送

> **远程 vs 本地**（统一架构）：
> - bare clone 到 `~/.perstate/<repo-name>.git/`，worktree 在 `~/.perstate/worktrees/<repo-name>/<branch>/`
> - **远程 git URL**（`git@...` 推荐 / `https://...`）：push/pull 走网络
> - **本地路径**：push/pull 走本地文件系统（瞬时）。不是 git 仓库时自动 `git init`
> - 多 repo 共存，切换不清理旧 repo（本地缓存）

---

## 会话绑定（`save`/`search`/`info`/`view`/`fork`/`switch` 的入口）

**执行 `/perstate save`、`/perstate search`、`/perstate info`、`/perstate view`、`/perstate fork`、`/perstate switch` 前，先走会话绑定流程确定 branch。**

> `/perstate`（无参数，状态检查）和 `/perstate prune` 不需要会话绑定。

### 场景 1：首次安装（config 不存在）

检查系统提示词是否指定了 `perstate repo: <url>`：
- **已指定** → 直接 `scripts/perstate-init.sh --repo <url> --branch <perstate branch 或 main> --yes`，完成后继续原命令
- **未指定** → 用 AskUserQuestion 收集 repo+branch（同"初始化"步骤 1），执行 init 后继续原命令

### 场景 2：会话首次绑定（config 存在，session 未绑定）

检查系统提示词是否指定了 branch（见场景 3）。未指定 → 用结构化交互确认：
"当前默认使用个人记忆（`<default_branch>` 分支）。确认？或输入新的分支名："
- 确认 → 绑定 `default_branch`；输入新分支名 → 绑定该分支（不存在时自动创建）

写入 config：
```bash
grep -q "^sessions:" ~/.perstate/config.yml || echo "sessions:" >> ~/.perstate/config.yml
cat >> ~/.perstate/config.yml << EOF
  <session-id>:
    branch: <branch>
EOF
```

### 场景 3：系统提示词指定（无需确认）

系统提示词中可包含以下指定，用于跳过用户确认：
```
perstate repo: <repo-url>       # 仅当 config 不存在时生效，跳过 init 确认
perstate branch: <branch-name>  # 仅当 session 未绑定时生效，跳过会话绑定确认
```
> **本地配置优先**：config 已存在则忽略 `perstate repo:`，session 已绑定则忽略 `perstate branch:`。系统提示词只在首次配置时起作用。发现指定后，直接写入 session 绑定（同场景 2）。

### 场景 4：已绑定

session 已有绑定 → **直接使用**，不再提示：
```bash
grep -q "^  <session-id>:" ~/.perstate/config.yml && echo "已绑定" || echo "未绑定"
SESSION_BRANCH=$(grep -A1 "^  <session-id>:" ~/.perstate/config.yml | grep "branch:" | sed 's/^[^:]*: *//')
```

### 所有场景完成后：准备 worktree + 同步

会话绑定确定 branch 后：
- **save/search**：Agent 手动执行 prepare → `cd "$(scripts/perstate-prepare.sh --session-id <id>)"`
- **info/view/fork/switch**：脚本内部已自动调 prepare.sh，直接调用即可

`perstate-prepare.sh` 自动完成：worktree 创建/复用 + `git fetch origin` + `git pull --ff-only`，确保本地分支与远程一致。

> **同步缓存（性能）**：`prepare.sh` 按 `<repo>__<branch>` 在 `~/.perstate/.sync/` 缓存上次同步时间戳。缓存窗口内（写 60s / 读 300s）完全跳过 `git fetch` + `git pull`——一次 save 紧接 search 可零网络往返。标志：`--read`（读模式，更长窗口）、`--no-sync`（完全跳过网络）、`--force-sync`（忽略缓存）、`--sync-window <秒>`（自定义窗口）。

> **内容索引（大规模检索）**：`perstate-index.sh` 在 `~/.perstate/.index/<repo>__<branch>.content` 构建临时内容索引——所有实体/关系文件内容拼成单流。`search` 和 `info` 在索引 fresh（按 git HEAD 自动检测）时使用索引，而非用 `grep -r` 扫描 40 万+ 文件。100k 实体 / 300k 关系：search 从 ~120s（`grep -r`）降到 ~5s（索引 awk 扫描），24x 提升。索引是临时缓存，非知识图谱数据源——仅在重建失败时回退 `grep -r`。**自动刷新**：索引缺失或过期（HEAD 不匹配）时 `search`/`info` 自动重建，用户无需手动维护。显式重建用 `scripts/perstate-index.sh --worktree <path> --rebuild`。

---

## 仓库结构

```
entities/
  <entity-id>/
    entity.md                   # 实体元数据 + 自由知识正文
    <relation-type>/            # 出关系目录（如 depends-on/, enables/）
      <target-id>.md            # 一条关系：此实体 --type--> 目标实体
schema/
  ontology.md                   # 实体类型、关系类型定义
```

文件系统即索引：`ls entities/` 列出所有实体，`ls entities/<id>/` 列出出关系类型。

### entity-id 命名规范

kebab-case，英文优先（如 `llm-evaluation`），必须合法作目录名/文件名。

---

## 文件格式

### entity.md

```markdown
---
id: llm-evaluation
label: 大模型评测
type: domain
aliases: [LLM evaluation, model benchmarking]
created_at: 2026-07-14
updated_at: 2026-07-15
sources: ["arxiv:2505.20416", "github:user/repo"]
---

## 概述

大模型评测是对LLM能力的系统性衡量...

## 核心洞察

（关于这个实体本身的知识，不涉及具体关系）

## 来源

- arxiv:2505.20416 — 论文 PDF（§4 Method, §5.3 Scaling）
- github:user/repo — README + 源码（background_review.py#L1-L25）
```

### 关系文件（`entities/<from>/<type>/<to>.md`）

```markdown
---
from: llm-evaluation
to: harness
type: depends-on
created_at: 2026-07-14
updated_at: 2026-07-15
valid_until: null
sources: ["arxiv:2505.20416 §4", "chat:2026-07-14"]
---

## 洞察

大模型评测本质上依赖 harness 的工程化能力...
```

### 时序字段

| 字段 | 含义 |
|------|------|
| `created_at` | 首次记录日期 |
| `updated_at` | 最近修改日期 |
| `valid_until` | `null` = 仍然有效；填日期 = 已被取代（软删除） |
| git history | 完整溯源（`git log --follow <file>`） |

---

## 写入流程（`/perstate save`）

### 1. 提取实体和关系

从对话洞察（或用户指定信息）中识别：
- **实体**（概念、领域、技术）
- **关系**（depends-on、enables、contradicts 等）
- **关系内容**（每条关系上的结晶洞察）

### 2. 去重、消歧、合并

对每个实体：
```bash
ls entities/ | grep -i "<entity-id>"           # 按 id 查
grep -rl "label:.*<label>" entities/            # 按 label 查
grep -rl "<alias>" entities/*/entity.md          # 按 alias 查
```
- 无匹配 → 新建；唯一匹配 → 合并（更新 frontmatter，追加正文）；多个匹配 → 上下文消歧

对每个关系：
```bash
ls entities/<from>/<type>/ | grep "<target>"
```
- 无匹配 → 新建；有匹配 → 合并（追加洞察）

### 3. 写入文件

按"文件格式"章节的模板创建/更新文件，替换 `<占位符>` 为实际值：

**新建实体：**
```bash
mkdir -p entities/<id>
# 按 entity.md 模板写入 entities/<id>/entity.md
```

**合并实体：** 读旧内容 → frontmatter 更新 `updated_at` + `aliases` 并集 + `sources` 追加 → 正文追加 `###` 子标题（带日期）→ 用 Edit 工具

**新建关系：**
```bash
mkdir -p entities/<from>/<type>
# 按关系文件模板写入 entities/<from>/<type>/<to>.md
```

**合并关系：** 读旧内容 → frontmatter 更新 `updated_at` + `sources` 追加 → 正文追加 `###` 子标题 → 用 Edit 工具

**删除：** 定位目标 → 软删除（设 `valid_until`）或硬删除（`rm` + 清理空目录）

### 4. 提交

```bash
scripts/perstate-commit.sh --message "perstate: <summary>" --session-id <session-id>
```

**以上步骤必须在同一 turn 内同步完成。绝不跨 turn 拆分准备和提交。**

---

## 查询模式（`/perstate search`）

> Agent 先执行 prepare.sh 同步 worktree，然后在 worktree 中用 shell 命令查询。

**基本查询：**
```bash
cat entities/<id>/entity.md                    # 单实体
ls entities/                                     # 全量概览
ls entities/<id>/                                # 列出出关系类型
ls entities/<id>/depends-on/                    # 特定关系类型
cat entities/<id>/depends-on/<target>.md         # 读取一条关系
grep -rl "关键词" entities/ | head -5             # 关键词搜索
```

**高级查询：**
```bash
# 多跳遍历
FIRST_HOP=$(ls entities/X/depends-on/ | sed 's/\.md$//')
for target in $FIRST_HOP; do echo "=== $target ==="; ls entities/$target/depends-on/ 2>/dev/null; done

# 反向查找（谁指向 X？）
find entities/ -name "X.md" -type f
grep -rl "to: X" entities/

# 时序查询
ls -lt entities/X/depends-on/
git log --oneline -10

# 子图提取（2 跳）
find entities/X/ -name "*.md" -not -name "entity.md"
find entities/ -path "*/X.md"

# 只看有效关系
grep -rl "valid_until: null" entities/X/depends-on/
```

**自然语言查询**：提取关键词 → `grep -rl` 定位 → 读取匹配文件 → 综合总结
**结果聚合**：多跳/多文件查询后合并 → 去重 → 按相关度或时间排序 → 综合总结

---

## 命令补充

**info**：输出仓库、分支、路径、大小、实体数、关系数（有效/已取代）、最近提交。脚本内部自动调 prepare.sh。

**view**：生成交互式 HTML 图谱（sigma.js v3 WebGL + graphology/forceatlas2，经 esm.sh 加载），自动在浏览器打开。渲染全图（去掉 1000 节点上限）。亮色主题、节点按 entity type 着色、细灰边、悬停药丸、选中邻居高亮。脚本内部自动调 prepare.sh。

**fork `<name>`**：基于当前分支 fork 新分支并重新绑定。脚本自动完成：读当前绑定 → 创建新分支 → 建 worktree → 更新 session 绑定 → 推送远程。fork 后后续写入作用于新分支，原分支记忆完整保留。

**switch `<branch>`**：切换到**已存在**的分支（与 fork 区别：fork 复制出新分支，switch 切换已有分支）。脚本自动完成：校验分支存在 → 原地改写 config 绑定 → 调 prepare 建 worktree 并 pull。常见用法：fork 实验后 `/perstate switch main` 切回。

**prune `[Nd]`**：两步流程（预览→确认→执行，见命令表）。清理对象：过期会话绑定（worktree mtime 超 N 天）、过期 worktree（先 `git worktree prune` 再 remove）、无效分支（本地有但远程已删除，`git branch -d` 安全删除）、孤儿内容索引（`.index/` 中分支已不存在的索引文件）。

---

## 触发时机

### 何时 search（召回）
- 回答可能涉及已有知识的问题之前，主动查询
- 会话开始时，如果话题在 Agent 专业域内，主动加载上下文
- 用户说 "回忆" / "之前" / "recall" / "memory" / "你之前说过"

### 何时 save（沉淀）
- 产生高维洞察后主动写入（高维 = 非平凡的分析、模式识别、因果推理、经验综合；不是数据统计或事实罗列）
- 用户说 "沉淀" / "记住" / "persist" / "save" / "保存洞察"
- 不触发：每条消息都写、无实质洞察的对话、纯执行任务
