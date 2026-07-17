#!/bin/bash
# perstate-prepare.sh — 写入前准备：会话绑定查找 + worktree 创建/复用 + 拉取最新
# 用法: perstate-prepare.sh --session-id <id> [--repo <url>] [--branch <branch>]
# 如果 --repo 和 --branch 未提供，从 config.yml 的 session 绑定读取
# 输出: worktree 路径（stdout 最后一行）

set -euo pipefail

# --- 参数解析 ---
SESSION_ID=""
REPO=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Escape regex special chars in session ID for grep
SID_SAFE=$(printf '%s' "$SESSION_ID" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

CONFIG=~/.perstate/config.yml

if [ ! -f "$CONFIG" ]; then
  echo "错误: 配置文件不存在 ($CONFIG)。请先运行 perstate-init.sh。" >&2
  exit 1
fi

# --- 确定 repo + branch ---
# repo 始终用 default_repo（唯一仓库）
REPO="${REPO:-$(grep "^default_repo:" "$CONFIG" | sed 's/^[^:]*: *//' || true)}"

if [ -z "$BRANCH" ]; then
  # 从 session 绑定读取 branch
  if [ -n "$SESSION_ID" ]; then
    SESSION_BRANCH=$(grep -A1 "^  ${SID_SAFE}:" "$CONFIG" 2>/dev/null | grep "branch:" | sed 's/^[^:]*: *//' || true)
    BRANCH="${BRANCH:-$SESSION_BRANCH}"
  fi
fi

# branch 仍无，用默认值
BRANCH="${BRANCH:-$(grep "^default_branch:" "$CONFIG" | sed 's/^[^:]*: *//' || true)}"

if [ -z "$REPO" ]; then
  echo "错误: 无法确定仓库。请在 config.yml 中配置 default_repo，或通过 --repo 指定。" >&2
  exit 1
fi

# --- 确定 worktree 路径（bare repo + worktree，统一远程和本地）---
REPO_NAME=$(basename "$REPO" .git)
BARE_REPO="$HOME/.perstate/$REPO_NAME.git"
WORKTREE_DIR="$HOME/.perstate/worktrees/$REPO_NAME"
WORKTREE="$WORKTREE_DIR/$BRANCH"

# 确保 bare repo 存在
if [ ! -d "$BARE_REPO" ]; then
  mkdir -p "$HOME/.perstate"
  git clone --bare "$REPO" "$BARE_REPO" >&2
  # 配置远程跟踪 ref（bare clone 默认不生成 refs/remotes/origin/*）
  git -C "$BARE_REPO" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$BARE_REPO" fetch origin >&2 2>/dev/null || true
fi

cd "$BARE_REPO"
git worktree prune
git fetch origin >&2 2>/dev/null || true

# 分支处理：本地不存在时从远程创建
if ! git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
    git branch "$BRANCH" "origin/$BRANCH" >&2
  elif git rev-parse --verify HEAD 2>/dev/null 1>&2; then
    DEFAULT_REMOTE=$(git symbolic-ref --short HEAD 2>/dev/null || git remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/^[^:]*: *//' || echo "main")
    git branch "$BRANCH" "origin/$DEFAULT_REMOTE" >&2
  fi
fi

# 创建或复用 worktree
mkdir -p "$WORKTREE_DIR"
if [ -d "$WORKTREE" ] && [ -f "$WORKTREE/.git" ]; then
  : # 复用
elif git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  git worktree add "$WORKTREE" "$BRANCH" >&2 2>/dev/null || {
    echo "错误: 分支 '${BRANCH}' 已在其他 worktree checkout。请等待或使用其他分支。" >&2
    exit 1
  }
else
  git worktree add --detach "$WORKTREE" >&2 2>/dev/null || true
fi
cd "$WORKTREE"
git rev-parse --abbrev-ref HEAD 2>/dev/null 1>&2 | grep -q "^HEAD$" && git checkout -b "$BRANCH" 2>/dev/null || true

# --- 拉取最新 ---
if ! git pull --ff-only origin "$BRANCH" >&2 2>/dev/null; then
  echo "警告: pull 失败（可能远程有分叉或网络问题），继续使用本地状态。" >&2
fi

# --- 写入 session 绑定（如未存在或 branch 不一致则更新）---
if [ -n "$SESSION_ID" ]; then
  if ! grep -q "^  ${SID_SAFE}:" "$CONFIG" 2>/dev/null; then
    # session 不存在，追加
    if ! grep -q "^sessions:" "$CONFIG" 2>/dev/null; then
      echo "" >> "$CONFIG"
      echo "sessions:" >> "$CONFIG"
    fi
    cat >> "$CONFIG" << EOF
  ${SESSION_ID}:
    branch: $BRANCH
EOF
  else
    # session 已存在，检查 branch 是否一致，不一致则更新
    EXISTING_BRANCH=$(grep -A1 "^  ${SID_SAFE}:" "$CONFIG" 2>/dev/null | grep "branch:" | sed 's/^[^:]*: *//' || true)
    if [ -n "$EXISTING_BRANCH" ] && [ "$EXISTING_BRANCH" != "$BRANCH" ]; then
      if [ "$(uname)" = "Darwin" ]; then
        sed -i '' "/^  ${SID_SAFE}:/,/branch:/s|branch: .*|branch: ${BRANCH}|" "$CONFIG"
      else
        sed -i "/^  ${SID_SAFE}:/,/branch:/s|branch: .*|branch: ${BRANCH}|" "$CONFIG"
      fi
    fi
  fi
fi

# --- 输出 worktree 路径 ---
echo "$WORKTREE"
