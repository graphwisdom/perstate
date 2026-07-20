#!/bin/bash
# benchmark-perf.sh — perstate 性能基准测试（save/search/info/view 延迟）
# 用法: benchmark-perf.sh [scale1 scale2 ...] [--worktree <path>]
# 默认测试 scale: 100 1000 5000
# 输出: JSON 格式延迟报告

set -euo pipefail

SCALES=()
WORKTREE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERSTATE_SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)/scripts"

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    --) shift; break ;;
    [0-9]*) SCALES+=("$1"); shift ;;
    *) shift ;;
  esac
done

if [ ${#SCALES[@]} -eq 0 ]; then
  SCALES=(100 1000 5000)
fi

# 结果收集
RESULTS_FILE="$(mktemp)"
echo '{"benchmarks":[' > "$RESULTS_FILE"
FIRST=1

bench_time() {
  # 用 /usr/bin/time 测量墙钟时间，输出秒
  # 注意：丢弃被测命令的 stdout/stderr，只取计时数值，避免 banner/统计输出污染 JSON
  local start end
  start=$(date +%s.%N 2>/dev/null || gdate +%s.%N 2>/dev/null || python3 -c "import time;print(time.time())")
  "$@" >/dev/null 2>&1
  end=$(date +%s.%N 2>/dev/null || gdate +%s.%N 2>/dev/null || python3 -c "import time;print(time.time())")
  python3 -c "print(f'{$end - $start:.3f}')"
}

run_scale() {
  local scale="$1"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local graph_dir="$tmp_dir/graph-$scale"
  
  echo "  生成 $scale 实体的合成图谱..." >&2
  bash "$SCRIPT_DIR/gen-synthetic-graph.sh" "$graph_dir" "$scale" 3 >&2
  
  # 初始化为 git 仓库（模拟 worktree）
  cd "$graph_dir"
  git init -b benchmark >&2 2>/dev/null
  git add . >&2 2>/dev/null
  git commit -m "init benchmark graph $scale" >&2 2>/dev/null
  cd - >&2
  
  local entity_count relation_count
  entity_count=$(find "$graph_dir/entities" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  relation_count=$(find "$graph_dir/entities" -name "*.md" -not -name "entity.md" 2>/dev/null | wc -l | tr -d ' ')
  
  echo "  实体=$entity_count 关系=$relation_count" >&2
  
  # --- Bench 1: search（关键词检索） ---
  echo "  [bench] search..." >&2
  local search_time
  search_time=$(bench_time bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
    --worktree "$graph_dir" --session-id bench "benchmark" --limit 20 2>/dev/null || echo "0")
  
  # --- Bench 2: search beacon（召回率验证用唯一标记） ---
  echo "  [bench] search beacon..." >&2
  beacon_start=$(python3 -c "import time;print(time.time())")
  beacon_result=$(bash "$PERSTATE_SCRIPTS/perstate-search.sh" \
    --worktree "$graph_dir" --session-id bench "SEARCHBEACON" --limit 500 2>/dev/null || true)
  beacon_end=$(python3 -c "import time;print(time.time())")
  beacon_search_time=$(python3 -c "print(f'{$beacon_end - $beacon_start:.3f}')")
  beacon_found=$(echo "$beacon_result" | grep -c "SEARCHBEACON" || echo "0")
  beacon_expected=$((scale / 10))
  
  # --- Bench 3: info（统计） ---
  echo "  [bench] info..." >&2
  local info_time
  info_time=$(bench_time bash "$PERSTATE_SCRIPTS/perstate-info.sh" \
    --worktree "$graph_dir" --session-id bench 2>/dev/null || echo "0")
  
  # --- Bench 4: view（图谱生成，不打开浏览器） ---
  echo "  [bench] view..." >&2
  local view_time
  view_time=$(bench_time bash "$PERSTATE_SCRIPTS/perstate-view.sh" \
    --worktree "$graph_dir" --session-id bench \
    --output "$tmp_dir/view-$scale.html" 2>/dev/null || echo "0")
  
  # --- Bench 5: save 模拟（prepare + 写入 + commit，不含网络） ---
  echo "  [bench] save (local commit only, no network)..." >&2
  # 写入一个新实体
  save_time=$(python3 -c "import time;print(time.time())")
  mkdir -p "$graph_dir/entities/bench-test-entity/depends-on"
  cat > "$graph_dir/entities/bench-test-entity/entity.md" << EOF
---
id: bench-test-entity
label: Benchmark Test Entity
type: concept
created_at: 2026-07-18
updated_at: 2026-07-18
---
## Overview
Test entity for save benchmark.
EOF
  cat > "$graph_dir/entities/bench-test-entity/depends-on/syn-entity-1.md" << EOF
---
from: bench-test-entity
to: syn-entity-1
type: depends-on
valid_until: null
---
## Insight
Benchmark test relation.
EOF
  cd "$graph_dir"
  git add -A >&2 2>/dev/null
  git commit -m "bench: save test" >&2 2>/dev/null
  cd - >&2
  save_end=$(python3 -c "import time;print(time.time())")
  save_time=$(python3 -c "print(f'{$save_end - $save_time:.3f}')")
  
  # 召回率
  local recall="1.0"
  if [ "$beacon_expected" -gt 0 ]; then
    recall=$(python3 -c "print(f'{min($beacon_found / $beacon_expected, 1.0):.2f}')")
  fi
  
  # 输出 JSON
  [ "$FIRST" -eq 1 ] || echo "," >> "$RESULTS_FILE"
  FIRST=0
  cat >> "$RESULTS_FILE" << JSON
  {"scale":$scale,"entities":$entity_count,"relations":$relation_count,
   "search_sec":$search_time,
   "search_beacon_sec":$beacon_search_time,"beacon_found":$beacon_found,"beacon_expected":$beacon_expected,"recall":$recall,
   "info_sec":$info_time,
   "view_sec":$view_time,
   "save_local_sec":$save_time}
JSON
  
  # 清理
  rm -rf "$tmp_dir"
}

echo "perstate 性能基准测试" >&2
echo "======================" >&2
for scale in "${SCALES[@]}"; do
  echo "Scale: $scale 实体" >&2
  run_scale "$scale"
done

echo "]}" >> "$RESULTS_FILE"
cat "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
