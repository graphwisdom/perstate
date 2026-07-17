#!/bin/bash
# perstate-info.sh — 查看配置、会话和统计信息
# 用法: perstate-info.sh [--session-id <id>] [--worktree <path>] [--status]
# --status: 仅显示配置和会话状态（不显示记忆统计），用于 /perstate 默认命令

set -euo pipefail

WORKTREE=""
SESSION_ID=""
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)   WORKTREE="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --status)     STATUS_ONLY=true; shift ;;
    *) shift ;;
  esac
done

# Escape regex special chars in session ID for grep
SID_SAFE=$(printf '%s' "$SESSION_ID" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

# 防护：--worktree 必须配合 --session-id 使用
if [ -n "$WORKTREE" ] && [ -z "$SESSION_ID" ]; then
  echo "错误: --worktree 必须配合 --session-id 使用，不能绕过会话绑定。" >&2
  exit 1
fi

CONFIG=~/.perstate/config.yml

echo "═══════════════════════════════════════"
echo "  perstate 信息"
echo "═══════════════════════════════════════"

# --- 1. 初始化配置 ---
echo ""
echo "── 初始化配置 ──"
if [ ! -f "$CONFIG" ]; then
  echo "  状态: 未初始化（config 不存在）"
  echo "  提示: 请先执行 /perstate init"
else
  DEFAULT_REPO=$(grep "^default_repo:" "$CONFIG" | sed 's/^[^:]*: *//' || true)
  DEFAULT_BRANCH=$(grep "^default_branch:" "$CONFIG" | sed 's/^[^:]*: *//' || true)
  echo "  默认仓库: ${DEFAULT_REPO:-未配置}"
  echo "  默认分支: ${DEFAULT_BRANCH:-未配置}"
fi

# --- 2. 当前会话信息 ---
echo ""
echo "── 当前会话 ──"
if [ -n "$SESSION_ID" ]; then
  echo "  会话 ID: $SESSION_ID"
  if [ -f "$CONFIG" ]; then
    SESSION_BRANCH=$(grep -A1 "^  ${SID_SAFE}:" "$CONFIG" 2>/dev/null | grep "branch:" | sed 's/^[^:]*: *//' || true)
    if [ -n "$SESSION_BRANCH" ]; then
      echo "  绑定分支: $SESSION_BRANCH"
    else
      echo "  绑定: 未绑定（首次调用时将提示确认）"
    fi
  else
    echo "  绑定: 未绑定（config 不存在）"
  fi
else
  echo "  会话 ID: 未提供（传 --session-id 查看）"
fi

# --- 状态模式下到此结束 ---
if [ "$STATUS_ONLY" = true ]; then
  echo ""
  echo "═══════════════════════════════════════"
  exit 0
fi

# --- 3. 准备 worktree + 远程同步 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$SESSION_ID" ] && [ -f "$CONFIG" ]; then
  WORKTREE=$("$SCRIPT_DIR/perstate-prepare.sh" --session-id "$SESSION_ID" 2>/dev/null || true)
fi

# --- 4. 当前 state 统计 ---
echo ""
echo "── 记忆统计 ──"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "  worktree 不存在，无法统计。"
  echo "  提示: 请先执行 /perstate init 或 /perstate 完成初始化。"
else
  cd "$WORKTREE"

  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  REMOTE=$(git remote get-url origin 2>/dev/null || echo "local")
  REPO_SIZE=$(du -sh . 2>/dev/null | cut -f1 || echo "unknown")

  echo "  仓库:   $REMOTE"
  echo "  分支:   $BRANCH"
  echo "  路径:   $WORKTREE"
  echo "  大小:   $REPO_SIZE"
  echo ""

  ENTITY_COUNT=0
  RELATION_COUNT=0
  VALID_RELATIONS=0
  SUPERSEDED=0
  UNDECLARED=0

  if [ -d entities ]; then
    ENTITY_COUNT=$(find entities/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    RELATION_COUNT=$(find entities/ -name "*.md" -not -name "entity.md" 2>/dev/null | wc -l | tr -d ' ')
    VALID_RELATIONS=$({ grep -rl "valid_until: null" entities/ 2>/dev/null || true; } | wc -l | tr -d ' ')
    SUPERSEDED=$({ grep -rl "valid_until:" entities/ 2>/dev/null || true; } | while IFS= read -r f; do grep -q "valid_until: null" "$f" || echo "$f"; done | wc -l | tr -d ' ')
    # 无 valid_until 字段的关系
    UNDECLARED=$(( RELATION_COUNT - VALID_RELATIONS - SUPERSEDED ))
  fi

  echo "  实体数:        $ENTITY_COUNT"
  echo "  关系总数:      $RELATION_COUNT"
  echo "    ├ 有效:      $VALID_RELATIONS"
  echo "    ├ 已取代:    $SUPERSEDED"
  echo "    └ 未声明:    $UNDECLARED"
  echo ""

  echo "  最近提交:"
  git log --oneline -5 2>/dev/null || echo "  无 git 历史"
fi

echo ""
echo "═══════════════════════════════════════"
