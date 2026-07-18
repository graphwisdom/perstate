#!/usr/bin/env python3
"""gen-large-graph.py — 高效生成大规模合成知识图谱用于压力测试
用法: python3 gen-large-graph.py <output-dir> <entity-count> [density]
默认 density=3（每实体 3 条出边），100k 实体 → 300k 关系
"""
import os, sys, random, time

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/perstate-large"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 100000
    density = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    types = ["domain","concept","technology","framework","person","insight"]
    rel_types = ["depends-on","enables","evolves-from","contradicts","specializes","part-of","applies-to"]
    topics = ["LLM","benchmark","evaluation","knowledge-graph","agent","distillation","reasoning",
              "retrieval","training","inference","dataset","fine-tuning","alignment","scaling",
              "architecture","transformer","attention","memory","context","prompt"]

    os.makedirs(f"{out}/entities", exist_ok=True)
    os.makedirs(f"{out}/schema", exist_ok=True)
    with open(f"{out}/schema/ontology.md","w") as f:
        f.write("# Ontology\n")

    # 用确定种子保证可重现
    rng = random.Random(42)
    start = time.time()

    # 批量生成：先建所有实体目录和 entity.md
    entity_dir_paths = []
    for i in range(1, n+1):
        eid = f"syn-entity-{i}"
        edir = f"{out}/entities/{eid}"
        os.makedirs(edir, exist_ok=True)

        t = types[i % len(types)]
        topic = topics[i % len(topics)]
        # 每 10 个实体一个 SEARCHBEACON
        if i % 10 == 0:
            beacon = f"SEARCHBEACON-{i} {topic} benchmark evaluation"
        else:
            beacon = f"{topic} benchmark evaluation"

        with open(f"{edir}/entity.md","w") as f:
            f.write(f"""---
id: {eid}
label: Synthetic Entity {i}
type: {t}
aliases: [syn-{i}, entity-{i}]
created_at: 2026-07-15
updated_at: 2026-07-16
sources: ["synthetic:benchmark"]
---

## Overview

Entity {i} is a synthetic {t} entity about {topic}.
This entity discusses {topic} in the context of benchmark and evaluation.
{beacon}

## Key Insights

- Insight about {topic} for entity {i}
- Related to benchmark methodology
- Evaluation criteria for {topic}
""")

        if i % 10000 == 0:
            elapsed = time.time() - start
            print(f"  entities: {i}/{n} ({elapsed:.1f}s)", file=sys.stderr)

    # 生成关系
    rel_count = 0
    for i in range(1, n+1):
        eid = f"syn-entity-{i}"
        for j in range(1, density+1):
            target = (i * 7919 + j * 31) % n + 1
            if target == i:
                target = target % n + 1
            target_id = f"syn-entity-{target}"
            rel_type = rel_types[(i + j) % len(rel_types)]

            rdir = f"{out}/entities/{eid}/{rel_type}"
            os.makedirs(rdir, exist_ok=True)

            # 20% superseded
            if (i * 7 + j * 13) % 5 == 0:
                vu = "2026-07-16"
            else:
                vu = "null"

            with open(f"{rdir}/{target_id}.md","w") as f:
                f.write(f"""---
from: {eid}
to: {target_id}
type: {rel_type}
created_at: 2026-07-15
updated_at: 2026-07-16
valid_until: {vu}
sources: ["synthetic:benchmark"]
---

## Insight

{eid} {rel_type} {target_id}. Benchmark insight about relation {j}.
""")
            rel_count += 1

        if i % 10000 == 0:
            elapsed = time.time() - start
            print(f"  relations: {i*density}/{n*density} ({elapsed:.1f}s)", file=sys.stderr)

    elapsed = time.time() - start
    print(f"完成: {n} 实体, {rel_count} 关系 ({elapsed:.1f}s)")
    print(f"  路径: {out}")
    print(f"  SearchBeacon 标记: {n//10} 个")


if __name__ == "__main__":
    main()
