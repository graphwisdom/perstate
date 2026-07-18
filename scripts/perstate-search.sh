#!/bin/bash
# perstate-search.sh — 高速记忆检索（read-only，可跳过网络同步）
# 用法: perstate-search.sh --session-id <id> [--worktree <path>] <keyword> [--limit N] [--reverse X] [--hop N]
#   <keyword>            关键词（支持正则，grep -E 语法）
#   --limit N            限制返回结果数（默认 20）
#   --reverse X          反向查找：谁指向实体 X？（等价 find -name X.md）
#   --hop N              多跳遍历：从 keyword 匹配的实体出发，沿 depends-on 跳 N 跳（默认 0 = 不跳）
#   --valid-only         仅返回有效关系（valid_until: null）
# 设计：读操作默认 --read 模式（跳过网络同步），保证 search < 10s
#       grep -RErI 批量检索，避免逐文件 fork；find -print0 | xargs -0 管道并行

set -euo pipefail

WORKTREE=""
SESSION_ID=""
KEYWORD=""
LIMIT=20
REVERSE=""
HOP=0
VALID_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)   WORKTREE="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --limit)      LIMIT="$2"; shift 2 ;;
    --reverse)    REVERSE="$2"; shift 2 ;;
    --hop)        HOP="$2"; shift 2 ;;
    --valid-only) VALID_ONLY=true; shift ;;
    -*) echo "未知参数: $1" >&2; exit 1 ;;
    *) KEYWORD="$1"; shift ;;
  esac
done

# Escape regex special chars in session ID for grep
SID_SAFE=$(printf '%s' "$SESSION_ID" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

# 防护：--worktree 必须配合 --session-id 使用
if [ -n "$WORKTREE" ] && [ -z "$SESSION_ID" ]; then
  echo "错误: --worktree 必须配合 --session-id 使用，不能绕过会话绑定。" >&2
  exit 1
fi

# --- 确定 worktree 路径 ---
if [ -z "$WORKTREE" ] && [ -n "$SESSION_ID" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CONFIG=~/.perstate/config.yml
  if [ -f "$CONFIG" ]; then
    # search 是只读操作，--read 模式跳过网络同步（缓存窗口内）
    WORKTREE=$("$SCRIPT_DIR/perstate-prepare.sh" --session-id "$SESSION_ID" --read 2>/dev/null || true)
  fi
fi

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "错误: worktree 不存在。请先运行 perstate-init.sh。" >&2
  exit 1
fi

cd "$WORKTREE"

if [ ! -d entities ]; then
  echo "无 entities 目录，知识图为空。"
  exit 0
fi

# --- 反向查找：谁指向 X？ ---
if [ -n "$REVERSE" ]; then
  echo "═══ 反向查找: 谁指向 $REVERSE ═══"
  # find -name X.md 列出所有指向 X 的关系文件（含路径）
  # 一次性 find + print0，避免逐目录扫描
  FOUND=0
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    # 提取 from/type 信息
    FROM=$(grep -m1 "^from:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
    TYPE=$(grep -m1 "^type:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
    echo "  $FROM --$TYPE--> $REVERSE"
    echo "    file: $f"
    FOUND=$((FOUND + 1))
    [ "$FOUND" -ge "$LIMIT" ] && break
  done < <(find entities/ -name "${REVERSE}.md" -not -name "entity.md" -print0 2>/dev/null)
  [ "$FOUND" -eq 0 ] && echo "  无结果。"
  exit 0
fi

if [ -z "$KEYWORD" ]; then
  echo "用法: perstate-search.sh --session-id <id> <keyword> [--limit N] [--reverse X] [--hop N]"
  echo "  keyword 支持正则（grep -E 语法）"
  exit 1
fi

# --- 关键词检索 ---
# 优化：grep -RErIn（-E 正则, -r 递归, -I 跳过二进制, -n 行号）
# 用 find -print0 + xargs -0 批量处理，避免 grep -r 在超大目录的 glob 开销
# 但 grep -r 本身已优化，直接使用更简洁

echo "═══ 检索: $KEYWORD ═══"
echo ""

MATCHED_ENTITIES=""
MATCH_COUNT=0

# 先检索匹配的文件（一次 grep -rl 批量扫描）
if [ "$VALID_ONLY" = true ]; then
  MATCHED_FILES=$(grep -rlIE "$KEYWORD" entities/ 2>/dev/null | while IFS= read -r f; do
    grep -q "valid_until: null" "$f" 2>/dev/null && echo "$f"
  done || true)
else
  MATCHED_FILES=$(grep -rlIE "$KEYWORD" entities/ 2>/dev/null || true)
fi

if [ -z "$MATCHED_FILES" ]; then
  echo "无匹配结果。"
  exit 0
fi

# 分类输出：entity.md = 实体匹配，其他 = 关系匹配
ENTITY_MATCHES=""
RELATION_MATCHES=""

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    */entity.md)
      eid=$(basename "$(dirname "$f")")
      ENTITY_MATCHES="${ENTITY_MATCHES}${eid}"$'\n'
      # 读取 label
      label=$(grep -m1 "^label:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
      snippet=$(grep -m1 -iIE "$KEYWORD" "$f" 2>/dev/null | sed 's/^[ \t]*//' | cut -c1-80 || true)
      echo "📌 实体: $eid ($label)"
      [ -n "$snippet" ] && echo "   $snippet"
      MATCH_COUNT=$((MATCH_COUNT + 1))
      ;;
    *)
      # 关系文件：entities/<from>/<type>/<to>.md
      FROM=$(grep -m1 "^from:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
      TO=$(grep -m1 "^to:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
      TYPE=$(grep -m1 "^type:" "$f" 2>/dev/null | sed 's/^[^:]*: *//' || true)
      snippet=$(grep -m1 -iIE "$KEYWORD" "$f" 2>/dev/null | sed 's/^[ \t]*//' | cut -c1-80 || true)
      echo "🔗 关系: $FROM --$TYPE--> $TO"
      [ -n "$snippet" ] && echo "   $snippet"
      MATCH_COUNT=$((MATCH_COUNT + 1))
      ;;
  esac
  [ "$MATCH_COUNT" -ge "$LIMIT" ] && break
done <<< "$MATCHED_FILES"

echo ""
echo "共 $MATCH_COUNT 条匹配。"

# --- 多跳遍历 ---
if [ "$HOP" -gt 0 ] && [ -n "$ENTITY_MATCHES" ]; then
  echo ""
  echo "═══ ${HOP} 跳遍历 ═══"
  CURRENT_HOP_ENTITIES=$(echo "$ENTITY_MATCHES" | sort -u | grep -v '^$' || true)
  VISITED=""
  for hop in $(seq 1 "$HOP"); do
    echo "--- 第 $hop 跳 ---"
    NEXT_HOP=""
    FOUND_HOP=0
    while IFS= read -r eid; do
      [ -z "$eid" ] && continue
      echo "$VISITED" | grep -q "^${eid}$" && continue
      VISITED="${VISITED}${eid}"$'\n'
      # 列出该实体的所有出边目标
      if [ -d "entities/$eid" ]; then
        for rel_dir in entities/$eid/*/; do
          [ -d "$rel_dir" ] || continue
          rel_type=$(basename "$rel_dir")
          for target_file in "$rel_dir"*.md; do
            [ -f "$target_file" ] || continue
            target=$(basename "$target_file" .md)
            echo "  $eid --$rel_type--> $target"
            NEXT_HOP="${NEXT_HOP}${target}"$'\n'
            FOUND_HOP=$((FOUND_HOP + 1))
            [ "$FOUND_HOP" -ge "$LIMIT" ] && break 2
          done
        done
      fi
    done <<< "$CURRENT_HOP_ENTITIES"
    CURRENT_HOP_ENTITIES=$(echo "$NEXT_HOP" | sort -u | grep -v '^$' || true)
    [ -z "$CURRENT_HOP_ENTITIES" ] && break
  done
fi
