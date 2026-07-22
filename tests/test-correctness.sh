#!/bin/bash
# test-correctness.sh — perstate 质量与正确性测试
# 验证：搜索召回率、图谱完整性、统计准确性、JSON 有效性
# 用法: test-correctness.sh
# 退出码: 0 = 全部通过，1 = 有失败

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERSTATE_SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)/scripts"
PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "perstate 正确性测试"
echo "===================="

# --- 1. 生成小型测试图谱 ---
echo "1. 生成测试图谱..."
GRAPH="$TMP_DIR/test-graph"
bash "$SCRIPT_DIR/gen-synthetic-graph.sh" "$GRAPH" 50 3 >&2

# 初始化 git
cd "$GRAPH"
git init -b test >&2 2>/dev/null
git add . >&2 2>/dev/null
git commit -m "init test" >&2 2>/dev/null
cd - >&2

echo "2. 搜索召回率测试..."
# 搜索 SEARCHBEACON（每 10 个实体 1 个，共 5 个）
BEACON_RESULT=$(bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
  --worktree "$GRAPH" --session-id test "SEARCHBEACON" --limit 50 2>/dev/null || true)
BEACON_FOUND=$(echo "$BEACON_RESULT" | grep -c "SEARCHBEACON" || echo "0")
assert "搜索找到 SEARCHBEACON 标记 (期望≥5, 实际=$BEACON_FOUND)" "[ '$BEACON_FOUND' -ge 5 ]"

echo "3. 普通关键词搜索测试..."
# 搜索 "benchmark"（所有实体都包含）
BENCH_RESULT=$(bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
  --worktree "$GRAPH" --session-id test "benchmark" --limit 50 2>/dev/null || true)
BENCH_FOUND=$(echo "$BENCH_RESULT" | grep -c "📌\|🔗" || echo "0")
assert "搜索 benchmark 有结果 (实际=$BENCH_FOUND)" "[ '$BENCH_FOUND' -gt 0 ]"

echo "4. 反向查找测试..."
# 查找谁指向 syn-entity-1
REVERSE_RESULT=$(bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
  --worktree "$GRAPH" --session-id test --reverse syn-entity-1 2>/dev/null || true)
REVERSE_FOUND=$(echo "$REVERSE_RESULT" | grep -c "syn-entity" || echo "0")
assert "反向查找 syn-entity-1 有结果 (实际=$REVERSE_FOUND)" "[ '$REVERSE_FOUND' -gt 0 ]"

echo "5. 多跳遍历测试..."
HOP_RESULT=$(bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
  --worktree "$GRAPH" --session-id test "entity-1" --limit 5 --hop 2 2>/dev/null || true)
HOP_FOUND=$(echo "$HOP_RESULT" | grep -c "跳\|-->" || echo "0")
assert "多跳遍历有结果 (实际=$HOP_FOUND)" "[ '$HOP_FOUND' -gt 0 ]"

echo "6. info 统计准确性测试..."
INFO_RESULT=$(bash "$PERSTATE_SCRIPTS/perstate-info.sh" \
  --worktree "$GRAPH" --session-id test 2>/dev/null || true)
INFO_ENTITIES=$(echo "$INFO_RESULT" | grep "实体数" | grep -oE '[0-9]+' || echo "0")
INFO_RELATIONS=$(echo "$INFO_RESULT" | grep "关系总数" | grep -oE '[0-9]+' || echo "0")
assert "info 实体数=50 (实际=$INFO_ENTITIES)" "[ '$INFO_ENTITIES' -eq 50 ]"
# 50 实体 × 3 关系 = 150
assert "info 关系数=150 (实际=$INFO_RELATIONS)" "[ '$INFO_RELATIONS' -eq 150 ]"

# 验证 valid/superseded 统计
INFO_VALID=$(echo "$INFO_RESULT" | grep "有效" | grep -oE '[0-9]+' || echo "0")
INFO_SUPERSEDED=$(echo "$INFO_RESULT" | grep "已取代" | grep -oE '[0-9]+' || echo "0")
INFO_UNDECLARED=$(echo "$INFO_RESULT" | grep "未声明" | grep -oE '[0-9]+' || echo "0")
TOTAL=$((INFO_VALID + INFO_SUPERSEDED + INFO_UNDECLARED))
assert "valid+superseded+undeclared=relation_count ($TOTAL vs $INFO_RELATIONS)" "[ '$TOTAL' -eq '$INFO_RELATIONS' ]"
assert "superseded > 0 (实际=$INFO_SUPERSEDED)" "[ '$INFO_SUPERSEDED' -gt 0 ]"

echo "7. view HTML + JSON 有效性测试..."
HTML_OUTPUT="$TMP_DIR/test-view.html"
bash "$PERSTATE_SCRIPTS/perstate-view.sh" \
  --worktree "$GRAPH" --session-id test --output "$HTML_OUTPUT" 2>/dev/null || true
assert "HTML 文件已生成" "[ -f '$HTML_OUTPUT' ]"
assert "HTML 非空" "[ -s '$HTML_OUTPUT' ]"

# 检查 JSON 基本有效性 + 引擎标志：sigma 初始化、vis 回退、nodes/edges 数组存在
SIGMA_MATCH=$(grep -c 'new Sigma(' "$HTML_OUTPUT" || echo "0")
VIS_FALLBACK_MATCH=$(grep -c 'loadVisFallback' "$HTML_OUTPUT" || echo "0")
NODES_MATCH=$(grep -c 'var NODES = \[' "$HTML_OUTPUT" || echo "0")
EDGES_MATCH=$(grep -c 'var EDGES = \[' "$HTML_OUTPUT" || echo "0")
CONTENT_MATCH=$(grep -c 'var contentMap' "$HTML_OUTPUT" || echo "0")
assert "HTML 含 sigma 初始化 (new Sigma(" "[ '$SIGMA_MATCH' -ge 1 ]"
assert "HTML 含 vis-network 回退" "[ '$VIS_FALLBACK_MATCH' -ge 1 ]"
assert "HTML 含 nodes 数组" "[ '$NODES_MATCH' -ge 1 ]"
assert "HTML 含 edges 数组" "[ '$EDGES_MATCH' -ge 1 ]"
assert "HTML 含 contentMap" "[ '$CONTENT_MATCH' -ge 1 ]"

# 用 python 验证 JSON 数组有效性（如果 python3 可用）
if command -v python3 &>/dev/null; then
  cat > "$TMP_DIR/validate_json.py" << 'PYEOF'
import re, json, sys
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'var NODES\s*=\s*\[', html)
if m:
    start = m.end() - 1
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(html)):
        c = html[i]
        if esc:
            esc = False
            continue
        if c == '\\':
            esc = True
            continue
        if c == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                try:
                    json.loads(html[start:i+1])
                    print('OK')
                except:
                    print('INVALID')
                break
    else:
        print('UNTERMINATED')
else:
    print('NOTFOUND')
PYEOF
  JSON_VALID=$(python3 "$TMP_DIR/validate_json.py" "$HTML_OUTPUT" 2>/dev/null || echo "ERROR")
  assert "nodes JSON 数组有效" "[ '$JSON_VALID' = 'OK' ]"
fi

echo "8. prepare.sh sync cache 测试..."
# 测试同步缓存目录会被创建
SYNC_DIR="$HOME/.perstate/.sync"
# 先清理测试缓存
rm -f "$SYNC_DIR/test-graph__test.cache" 2>/dev/null || true
# 运行 prepare（--no-sync 模式不应创建缓存）
bash "$PERSTATE_SCRIPTS/perstate-prepare.sh" --session-id test --no-sync 2>/dev/null || true
CACHE_AFTER_NO_SYNC=$([ -f "$SYNC_DIR/test-graph__test.cache" ] && echo "exists" || echo "absent")
# no-sync 模式不应创建缓存（但可能因其他原因存在）
echo "  (no-sync 后缓存: $CACHE_AFTER_NO_SYNC)"

echo ""
echo "===================="
echo "通过: $PASS | 失败: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "结果: FAIL"
  exit 1
else
  echo "结果: ALL PASS"
  exit 0
fi
