#!/bin/bash
# gen-synthetic-graph.sh — 生成合成知识图谱用于性能/质量基准测试
# 用法: gen-synthetic-graph.sh <output-dir> <entity-count> [relation-density]
#   entity-count: 实体数量（如 100, 1000, 5000）
#   relation-density: 每个实体的平均出边数（默认 3）
# 生成与 perstate 格式完全一致的 entities/ 结构

set -euo pipefail

OUTPUT_DIR="${1:?用法: gen-synthetic-graph.sh <output-dir> <entity-count> [density]}"
ENTITY_COUNT="${2:?需要 entity-count}"
DENSITY="${3:-3}"

# 实体类型池
TYPES=("domain" "concept" "technology" "framework" "person" "insight")
# 关系类型池
REL_TYPES=("depends-on" "enables" "evolves-from" "contradicts" "specializes" "part-of" "applies-to")

# 主题词池（用于生成有意义的内容，验证搜索召回率）
TOPICS=("LLM" "benchmark" "evaluation" "knowledge-graph" "agent" "distillation" "reasoning" "retrieval" "training" "inference" "dataset" "fine-tuning" "alignment" "scaling" "architecture" "transformer" "attention" "memory" "context" "prompt")

mkdir -p "$OUTPUT_DIR/entities" "$OUTPUT_DIR/schema"
echo "# Ontology" > "$OUTPUT_DIR/schema/ontology.md"

echo "生成 $ENTITY_COUNT 个实体，平均每个 $DENSITY 条出边..."

# 生成实体
for i in $(seq 1 "$ENTITY_COUNT"); do
  type_idx=$((i % ${#TYPES[@]}))
  etype="${TYPES[$type_idx]}"
  topic="${TOPICS[$((i % ${#TOPICS[@]}))]}"
  
  eid="syn-entity-$i"
  mkdir -p "$OUTPUT_DIR/entities/$eid"
  
  # 30% 的实体在内容中包含一个唯一可搜索的标记（用于搜索召回率验证）
  if [ $((i % 10)) -eq 0 ]; then
    SEARCH_TAG="SEARCHBEACON-$i $topic benchmark evaluation"
  else
    SEARCH_TAG="$topic benchmark evaluation"
  fi

  cat > "$OUTPUT_DIR/entities/$eid/entity.md" << EOF
---
id: $eid
label: Synthetic Entity $i
type: $etype
aliases: [syn-$i, entity-$i]
created_at: 2026-07-15
updated_at: 2026-07-16
sources: ["synthetic:benchmark"]
---

## Overview

Entity $i is a synthetic $etype entity about $topic.
This entity discusses $topic in the context of benchmark and evaluation.
$SEARCH_TAG

## Key Insights

- Insight about $topic for entity $i
- Related to benchmark methodology
- Evaluation criteria for $topic
EOF
done

# 生成关系
REL_COUNT=0
for i in $(seq 1 "$ENTITY_COUNT"); do
  eid="syn-entity-$i"
  for j in $(seq 1 "$DENSITY"); do
    # 目标实体：随机但确定（用 hash 保证可重现）
    target_idx=$(( (i * 7919 + j * 31) % ENTITY_COUNT + 1 ))
    [ "$target_idx" -eq "$i" ] && target_idx=$(( target_idx % ENTITY_COUNT + 1 ))
    target="syn-entity-$target_idx"
    
    rel_type_idx=$(( (i + j) % ${#REL_TYPES[@]} ))
    rel_type="${REL_TYPES[$rel_type_idx]}"
    
    mkdir -p "$OUTPUT_DIR/entities/$eid/$rel_type"
    
    # 20% 的关系标记为 superseded（valid_until 有值）
    if [ $(( (i * 7 + j * 13) % 5 )) -eq 0 ]; then
      valid_until="2026-07-16"
    else
      valid_until="null"
    fi
    
    cat > "$OUTPUT_DIR/entities/$eid/$rel_type/$target.md" << EOF
---
from: $eid
to: $target
type: $rel_type
created_at: 2026-07-15
updated_at: 2026-07-16
valid_until: $valid_until
sources: ["synthetic:benchmark"]
---

## Insight

$eid $rel_type $target. Benchmark insight about relation $j.
EOF
    REL_COUNT=$((REL_COUNT + 1))
  done
done

echo "完成: $ENTITY_COUNT 实体, $REL_COUNT 关系"
echo "  路径: $OUTPUT_DIR"
echo "  SearchBeacon 标记: 每 10 个实体一个（共 $((ENTITY_COUNT / 10)) 个）"
