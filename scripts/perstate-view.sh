#!/bin/bash
# perstate-view.sh — 在浏览器渲染记忆图谱
# 用法: perstate-view.sh [--session-id <id>] [--worktree <path>] [--output <path>]
# 生成交互式 HTML 图谱，自动在默认浏览器打开
# 依赖: 仅标准工具（bash + 基础命令），HTML 内嵌 vis-network CDN

set -euo pipefail

WORKTREE=""
SESSION_ID=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)   WORKTREE="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# 防护：--worktree 必须配合 --session-id 使用
if [ -n "$WORKTREE" ] && [ -z "$SESSION_ID" ]; then
  echo "错误: --worktree 必须配合 --session-id 使用，不能绕过会话绑定。" >&2
  exit 1
fi

# --- JSON 转义（awk 实现，用于批量处理）---
# 用法: echo "$str" | json_escape.awk → 输出转义后的 JSON 字符串值（含引号）
# 单次扫描所有文件，避免逐文件 fork grep/sed/cat

# --- 准备 worktree + 远程同步 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$WORKTREE" ] && [ -n "$SESSION_ID" ]; then
  CONFIG=~/.perstate/config.yml
  if [ -f "$CONFIG" ]; then
    # view 是只读操作，使用 --read 模式
    WORKTREE=$("$SCRIPT_DIR/perstate-prepare.sh" --session-id "$SESSION_ID" --read 2>/dev/null || true)
  fi
fi

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo "错误: worktree 不存在。请先运行 perstate-init.sh。" >&2
  exit 1
fi

cd "$WORKTREE"

# --- 输出路径 ---
if [ -z "$OUTPUT" ]; then
  OUTPUT="/tmp/perstate-graph-$(date +%s).html"
fi

# --- 提取图数据（awk 批量处理，避免逐文件 fork grep/sed/cat）---
# 节点：entities/*/entity.md 的 id 和 label
# 边：entities/<from>/<type>/<to>.md
# 用 awk 单进程扫描所有文件，大幅减少 fork 开销；JSON 写入临时文件以规避 ARG_MAX

MAX_NODES=200000
MAX_EDGES=2000000

# 每个临时文件存"项"（逗号分隔，无外层括号）；最后统一包上 [] / {}
NODES_ITEMS="$(mktemp 2>/dev/null || echo /tmp/perstate_nodes_$$.txt)"
EDGES_ITEMS="$(mktemp 2>/dev/null || echo /tmp/perstate_edges_$$.txt)"
CONTENT_ITEMS="$(mktemp 2>/dev/null || echo /tmp/perstate_content_$$.txt)"
: > "$NODES_ITEMS"; : > "$EDGES_ITEMS"; : > "$CONTENT_ITEMS"
NODE_COUNT=0
EDGE_COUNT=0

# 收集 entity 文件列表（限制 MAX_NODES）
ENTITY_FILES=()
if [ -d entities ]; then
  for entity_dir in entities/*/; do
    [ -d "$entity_dir" ] || continue
    [ -f "${entity_dir}entity.md" ] || continue
    [ "$NODE_COUNT" -ge "$MAX_NODES" ] && break
    ENTITY_FILES+=("${entity_dir}entity.md")
    NODE_COUNT=$((NODE_COUNT + 1))
  done
fi

# 提取节点 JSON + content map（awk 单次扫描所有 entity.md）
if [ ${#ENTITY_FILES[@]} -gt 0 ]; then
  # 节点项 → NODES_ITEMS（每项一行，逗号由后处理补齐）
  awk '
    function esc(s){ gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); gsub(/\n/, "\\n", s); return s }
    BEGIN { in_fm=0; content=""; id=""; label=""; type=""; dir_id=""; first=1 }
    FNR==1 {
      if(!first){
        eid=id; if(eid=="") eid=dir_id
        elabel=label; if(elabel=="") elabel=eid
        printf "{\"id\":\"%s\",\"label\":\"%s\",\"group\":\"%s\",\"title\":\"%s\"}\n", esc(eid), esc(elabel), esc(type), esc(elabel)
      }
      first=0; id=""; label=""; type=""; content=""; in_fm=0
      dir=FILENAME; sub(/^.*entities\//,"",dir); sub(/\/entity\.md$/,"",dir); dir_id=dir
      if($0=="---"){ in_fm=1; next }
      content=$0 "\n"; next
    }
    in_fm && $0=="---" { in_fm=0; next }
    in_fm {
      if($0 ~ /^id:/){ id=$0; sub(/^id:[ \t]*/,"",id) }
      else if($0 ~ /^label:/){ label=$0; sub(/^label:[ \t]*/,"",label) }
      else if($0 ~ /^type:/){ type=$0; sub(/^type:[ \t]*/,"",type) }
      next
    }
    { content=content $0 "\n" }
    END {
      if(!first){
        eid=id; if(eid=="") eid=dir_id
        elabel=label; if(elabel=="") elabel=eid
        printf "{\"id\":\"%s\",\"label\":\"%s\",\"group\":\"%s\",\"title\":\"%s\"}\n", esc(eid), esc(elabel), esc(type), esc(elabel)
      }
    }
  ' "${ENTITY_FILES[@]}" >> "$NODES_ITEMS" 2>/dev/null

  # 节点 content map 项 → CONTENT_ITEMS
  awk '
    function esc(s){ gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); gsub(/\n/, "\\n", s); return s }
    BEGIN { in_fm=0; content=""; id=""; dir_id=""; first=1 }
    FNR==1 {
      if(!first){ eid=id; if(eid=="") eid=dir_id; printf "\"%s\":\"%s\"\n", esc(eid), esc(content) }
      first=0; id=""; content=""; in_fm=0
      dir=FILENAME; sub(/^.*entities\//,"",dir); sub(/\/entity\.md$/,"",dir); dir_id=dir
      if($0=="---"){ in_fm=1; next }
      content=$0 "\n"; next
    }
    in_fm && $0=="---" { in_fm=0; next }
    in_fm { if($0 ~ /^id:/){ id=$0; sub(/^id:[ \t]*/,"",id) }; next }
    { content=content $0 "\n" }
    END { if(!first){ eid=id; if(eid=="") eid=dir_id; printf "\"%s\":\"%s\"\n", esc(eid), esc(content) } }
  ' "${ENTITY_FILES[@]}" >> "$CONTENT_ITEMS" 2>/dev/null
fi

# 提取边 JSON + content map（awk 单次扫描所有关系文件，限制 MAX_EDGES）
if [ -d entities ]; then
  EDGE_FILES=()
  while IFS= read -r -d '' f; do
    [ "$EDGE_COUNT" -ge "$MAX_EDGES" ] && break
    EDGE_FILES+=("$f")
    EDGE_COUNT=$((EDGE_COUNT + 1))
  done < <(find entities/ -name "*.md" -not -name "entity.md" -print0 2>/dev/null)

  if [ ${#EDGE_FILES[@]} -gt 0 ]; then
    # 边项 → EDGES_ITEMS
    awk '
      function esc(s){ gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); gsub(/\n/, "\\n", s); return s }
      BEGIN { in_fm=0; content=""; efrom=""; eto=""; etype=""; valid=""; first=1 }
      FNR==1 {
        if(!first){
          lbl=etype; if(valid!="" && valid!="null") lbl=lbl " (superseded)"
          eid=esc(efrom) "\xe2\x86\x92" esc(eto) ":" esc(lbl)
          printf "{\"from\":\"%s\",\"to\":\"%s\",\"label\":\"%s\",\"id\":\"%s\"}\n", esc(efrom), esc(eto), esc(lbl), eid
        }
        first=0; efrom=""; eto=""; etype=""; valid=""; content=""; in_fm=0
        if($0=="---"){ in_fm=1; next }
        content=$0 "\n"; next
      }
      in_fm && $0=="---" { in_fm=0; next }
      in_fm {
        if($0 ~ /^from:/){ efrom=$0; sub(/^from:[ \t]*/,"",efrom) }
        else if($0 ~ /^to:/){ eto=$0; sub(/^to:[ \t]*/,"",eto) }
        else if($0 ~ /^type:/){ etype=$0; sub(/^type:[ \t]*/,"",etype) }
        else if($0 ~ /^valid_until:/){ valid=$0; sub(/^valid_until:[ \t]*/,"",valid) }
        next
      }
      { content=content $0 "\n" }
      END {
        if(!first){
          lbl=etype; if(valid!="" && valid!="null") lbl=lbl " (superseded)"
          eid=esc(efrom) "\xe2\x86\x92" esc(eto) ":" esc(lbl)
          printf "{\"from\":\"%s\",\"to\":\"%s\",\"label\":\"%s\",\"id\":\"%s\"}\n", esc(efrom), esc(eto), esc(lbl), eid
        }
      }
    ' "${EDGE_FILES[@]}" >> "$EDGES_ITEMS" 2>/dev/null

    # 边 content map 项 → CONTENT_ITEMS（合并到同一文件）
    awk '
      function esc(s){ gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); gsub(/\n/, "\\n", s); return s }
      BEGIN { in_fm=0; content=""; efrom=""; eto=""; etype=""; valid=""; first=1 }
      FNR==1 {
        if(!first){
          lbl=etype; if(valid!="" && valid!="null") lbl=lbl " (superseded)"
          eid=esc(efrom) "\xe2\x86\x92" esc(eto) ":" esc(lbl)
          printf "\"%s\":\"%s\"\n", eid, esc(content)
        }
        first=0; efrom=""; eto=""; etype=""; valid=""; content=""; in_fm=0
        if($0=="---"){ in_fm=1; next }
        content=$0 "\n"; next
      }
      in_fm && $0=="---" { in_fm=0; next }
      in_fm {
        if($0 ~ /^from:/){ efrom=$0; sub(/^from:[ \t]*/,"",efrom) }
        else if($0 ~ /^to:/){ eto=$0; sub(/^to:[ \t]*/,"",eto) }
        else if($0 ~ /^type:/){ etype=$0; sub(/^type:[ \t]*/,"",etype) }
        else if($0 ~ /^valid_until:/){ valid=$0; sub(/^valid_until:[ \t]*/,"",valid) }
        next
      }
      { content=content $0 "\n" }
      END {
        if(!first){
          lbl=etype; if(valid!="" && valid!="null") lbl=lbl " (superseded)"
          eid=esc(efrom) "\xe2\x86\x92" esc(eto) ":" esc(lbl)
          printf "\"%s\":\"%s\"\n", eid, esc(content)
        }
      }
    ' "${EDGE_FILES[@]}" >> "$CONTENT_ITEMS" 2>/dev/null
  fi
fi

# 组装 JSON：项文件每行一项，用 paste -sd, 连接，再包上 [] / {}
NODES_DATA="[ $(paste -sd, "$NODES_ITEMS" 2>/dev/null || true) ]"
EDGES_DATA="[ $(paste -sd, "$EDGES_ITEMS" 2>/dev/null || true) ]"
CONTENT_DATA="{ $(paste -sd, "$CONTENT_ITEMS" 2>/dev/null || true) }"
# 清理临时文件
rm -f "$NODES_ITEMS" "$EDGES_ITEMS" "$CONTENT_ITEMS" 2>/dev/null

PARTIAL_WARN=""
if [ "$NODE_COUNT" -ge "$MAX_NODES" ] || [ "$EDGE_COUNT" -ge "$MAX_EDGES" ]; then
  PARTIAL_WARN=" | ⚠ partial"
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

# --- 生成 HTML（数据通过变量注入，大图时 paste 已避免逐文件 fork）---
BADGE=$(basename "$(git remote get-url origin 2>/dev/null || echo "local")" .git 2>/dev/null || echo "local")

cat > "$OUTPUT" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>perstate — ${BRANCH}</title>
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <style>
    body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; overflow: hidden; }
    #header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: #e0e0e0; padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; }
    #header h1 { margin: 0; font-size: 18px; font-weight: 600; }
    #header .meta { font-size: 12px; color: #7a8a9a; margin-top: 4px; }
    #header .badge { background: rgba(255,255,255,0.1); border-radius: 12px; padding: 2px 10px; font-size: 11px; color: #a0b0c0; }
    #graph { width: 100vw; height: calc(100vh - 56px); background: #ffffff; }
    #preview { display: none; position: fixed; top: 72px; right: 16px; width: 520px; max-height: calc(100vh - 96px); overflow-y: auto; padding: 20px; background: white; border-radius: 10px; box-shadow: 0 8px 32px rgba(0,0,0,0.18); z-index: 100; }
    #preview h2 { margin: 0 0 12px 0; font-size: 17px; color: #1a1a2e; border-bottom: 2px solid #f0f0f0; padding-bottom: 8px; }
    #preview .content { font-size: 13px; line-height: 1.7; color: #333; }
    #preview .content h1, #preview .content h2, #preview .content h3 { margin-top: 16px; color: #1a1a2e; }
    #preview .content code { background: #f5f5f5; padding: 1px 4px; border-radius: 3px; font-size: 12px; }
    #preview .content a { color: #3498db; }
    #preview .meta-table { width: 100%; border-collapse: collapse; margin: 0 0 14px 0; font-size: 12px; }
    #preview .meta-table td { padding: 3px 8px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
    #preview .meta-table .meta-key { color: #888; white-space: nowrap; width: 90px; font-weight: 500; }
    #preview .meta-table .meta-val { color: #333; word-break: break-all; }
    #preview .body-section { border-top: 1px solid #eee; padding-top: 12px; }
    #preview .close { position: absolute; top: 10px; right: 16px; cursor: pointer; color: #bbb; font-size: 20px; line-height: 1; }
    #preview .close:hover { color: #333; }
  </style>
</head>
<body>
  <div id="header">
    <div>
      <h1>perstate</h1>
      <div class="meta">branch: ${BRANCH} | nodes: ${NODE_COUNT} | edges: ${EDGE_COUNT}${PARTIAL_WARN}</div>
    </div>
    <div class="badge">${BADGE}</div>
  </div>
  <div id="graph"></div>
  <div id="preview">
    <span class="close" onclick="document.getElementById('preview').style.display='none'">✕</span>
    <h2 id="preview-title"></h2>
    <div class="content" id="preview-content"></div>
  </div>
  <script>
    var NODES = ${NODES_DATA};
    var EDGES = ${EDGES_DATA};
    var contentMap = ${CONTENT_DATA};

    var GROUP_COLORS = {
      domain: '#e57373', concept: '#64b5f6', technology: '#81c784',
      framework: '#ffb74d', person: '#ba68c8', insight: '#4db6ac'
    };
    var DEFAULT_COLOR = '#6b7280';
    function nodeColor(g){ return GROUP_COLORS[g] || DEFAULT_COLOR; }

    // FA2 tiered settings (ported from GitNexus useSigma.ts)
    function getFA2Settings(nodeCount){
      var isSmall = nodeCount < 500;
      var isMedium = nodeCount >= 500 && nodeCount < 2000;
      var isLarge = nodeCount >= 2000 && nodeCount < 10000;
      return {
        gravity: isSmall ? 0.5 : isMedium ? 0.15 : isLarge ? 0.03 : 0.01,
        scalingRatio: isSmall ? 30 : isMedium ? 80 : isLarge ? 160 : 280,
        slowDown: isSmall ? 1 : isMedium ? 2 : isLarge ? 3 : 5,
        barnesHutOptimize: nodeCount > 200,
        barnesHutTheta: isLarge ? 0.7 : 0.5,
        strongGravityMode: false, outboundAttractionDistribution: true,
        linLogMode: false, adjustSizes: false, edgeWeightInfluence: 0
      };
    }
    function getScaledNodeSize(base, nodeCount){
      if (nodeCount > 50000) return Math.max(1, base * 0.4);
      if (nodeCount > 20000) return Math.max(1.5, base * 0.5);
      if (nodeCount > 5000) return Math.max(2, base * 0.65);
      if (nodeCount > 1000) return Math.max(2.5, base * 0.8);
      return base;
    }

    var preview = document.getElementById('preview');
    var previewTitle = document.getElementById('preview-title');
    var previewContent = document.getElementById('preview-content');

    function renderPreview(rawContent) {
      if (!rawContent) return '<p style="color:#999">(no content available)</p>';
      var parts = rawContent.split(/^---$/m);
      var metaHtml = '';
      var bodyHtml = '';

      if (parts.length >= 3) {
        // Parse frontmatter (parts[1])
        var fmLines = parts[1].trim().split('\n');
        var metaRows = [];
        var inList = false;
        var listKey = '';
        var listItems = [];
        for (var i = 0; i < fmLines.length; i++) {
          var line = fmLines[i];
          var listMatch = line.match(/^\s+-\s+(.*)$/);
          if (listMatch && inList) {
            listItems.push(listMatch[1].trim());
            continue;
          }
          if (inList && listItems.length > 0) {
            metaRows.push('<tr><td class="meta-key">' + listKey + '</td><td class="meta-val">' + listItems.join(', ') + '</td></tr>');
            inList = false; listItems = [];
          }
          var m = line.match(/^(\w+):\s*(.*)$/);
          if (m) {
            var key = m[1], val = m[2].trim();
            if (val === '' || val === 'null' || val === '[]') continue;
            if (val === '') { inList = true; listKey = key; listItems = []; }
            else { metaRows.push('<tr><td class="meta-key">' + key + '</td><td class="meta-val">' + val + '</td></tr>'); }
          }
        }
        if (inList && listItems.length > 0) {
          metaRows.push('<tr><td class="meta-key">' + listKey + '</td><td class="meta-val">' + listItems.join(', ') + '</td></tr>');
        }
        if (metaRows.length > 0) {
          metaHtml = '<table class="meta-table">' + metaRows.join('') + '</table>';
        }
        // Body (parts[2] onward)
        bodyHtml = parts.slice(2).join('---').trim();
      } else {
        bodyHtml = rawContent.trim();
      }

      var bodyMarkdown = bodyHtml ? marked.parse(bodyHtml) : '';
      return metaHtml + (bodyMarkdown ? '<div class="body-section">' + bodyMarkdown + '</div>' : '');
    }

    function showNode(nodeId, node){
      previewTitle.textContent = (node.label || nodeId) + ' · ' + (node.group || 'unknown');
      previewContent.innerHTML = renderPreview(contentMap[nodeId] || '');
      preview.style.display = 'block';
    }
    function showEdge(from, to, label){
      previewTitle.textContent = from + ' → ' + to + ' · ' + label;
      var key = from + '→' + to + ':' + label;
      previewContent.innerHTML = renderPreview(contentMap[key] || '');
      preview.style.display = 'block';
    }

    // --- color helpers (ported from GitNexus useSigma.ts) ---
    function hexToRgb(hex){
      var r = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
      return r ? { r: parseInt(r[1],16), g: parseInt(r[2],16), b: parseInt(r[3],16) } : { r:100, g:100, b:100 };
    }
    function rgbToHex(r,g,b){
      return '#' + [r,g,b].map(function(x){ var h=Math.max(0,Math.min(255,Math.round(x))).toString(16); return h.length<2?'0'+h:h; }).join('');
    }
    function dimColor(hex, amount){
      var c = hexToRgb(hex), bg = { r:255, g:255, b:255 };
      return rgbToHex(bg.r+(c.r-bg.r)*amount, bg.g+(c.g-bg.g)*amount, bg.b+(c.b-bg.b)*amount);
    }
    function brightenColor(hex, factor){
      var c = hexToRgb(hex);
      return rgbToHex(c.r+((255-c.r)*(factor-1))/factor, c.g+((255-c.g)*(factor-1))/factor, c.b+((255-c.b)*(factor-1))/factor);
    }

    var EDGE_COLORS = {
      'depends-on': '#f39c12', 'enables': '#2ecc71', 'contradicts': '#e74c3c',
      'specializes': '#9b59b6', 'part-of': '#3498db', 'evolves-from': '#1abc9c',
      'applies-to': '#e67e22', 'instantiates': '#16a085'
    };
    var DEFAULT_EDGE_COLOR = '#3a3a4a';

    // --- sigma.js v3 renderer (primary engine) ---
    function renderSigma(Sigma, Graph, forceAtlas2, noverlap, EdgeArrowProgram, NodeCircleProgram){
      var graph = new Graph({ multi: true });
      // 节点均匀大小（对齐 vis 的均匀 dot），hub 仅极轻度放大
      var degree = {};
      NODES.forEach(function(n){ degree[n.id] = 0; });
      EDGES.forEach(function(e){ if(degree[e.from]!==undefined) degree[e.from]++; if(degree[e.to]!==undefined) degree[e.to]++; });
      var maxDeg = 1; for(var k in degree){ if(degree[k]>maxDeg) maxDeg=degree[k]; }
      var baseSize = getScaledNodeSize(4.5, NODES.length);
      NODES.forEach(function(n){
        var d = degree[n.id] || 0;
        var s = baseSize + Math.sqrt(d / maxDeg) * baseSize * 0.25;
        graph.addNode(n.id, { label: n.label, size: s, color: nodeColor(n.group), group: n.group, type: 'circle', x: Math.random(), y: Math.random() });
      });
      // 边：极细浅灰线，默认不显示 relation label（hover/selected 时再看），对齐 vis 的 airy 观感
      EDGES.forEach(function(e){
        if (graph.hasNode(e.from) && graph.hasNode(e.to))
          graph.addEdge(e.from, e.to, { label: e.label, color: '#d8dde4', size: 0.35, type: 'arrow' });
      });
      // FA2 力导向布局（散开）+ noverlap 防重叠（vis barnesHut 的碰撞感）
      var iterations = NODES.length > 10000 ? 400 : NODES.length > 2000 ? 600 : 800;
      try {
        if (forceAtlas2.assign) forceAtlas2.assign(graph, { iterations: iterations, settings: getFA2Settings(NODES.length) });
        else forceAtlas2(graph, { iterations: iterations, settings: getFA2Settings(NODES.length) });
      } catch(e){ console.warn('FA2 layout failed', e); }
      try {
        if (noverlap.assign) noverlap.assign(graph, { maxIterations: 160, ratio: 1.9, margin: 1.5 });
        else noverlap(graph, { maxIterations: 160, ratio: 1.9, margin: 1.5 });
      } catch(e){ console.warn('noverlap failed', e); }

      var selectedNode = null;
      var container = document.getElementById('graph');
      var renderer = new Sigma(graph, container, {
        renderLabels: true, labelFont: '-apple-system, sans-serif', labelSize: 11, labelWeight: '500',
        labelColor: { color: '#5a5a6a' }, labelRenderedSizeThreshold: 7, labelDensity: 0.12, labelGridCellSize: 80,
        renderEdgeLabels: false, edgeLabelFont: '-apple-system, sans-serif', edgeLabelSize: 9, edgeLabelWeight: 'normal', edgeLabelColor: { color: '#7a8088' },
        defaultNodeType: 'circle', nodeProgramClasses: { circle: NodeCircleProgram },
        defaultEdgeType: 'arrow', edgeProgramClasses: { arrow: EdgeArrowProgram },
        defaultNodeColor: DEFAULT_COLOR, defaultEdgeColor: '#d8dde4',
        minCameraRatio: 0.01, maxCameraRatio: 10, hideEdgesOnMove: false, hideLabelsOnMove: false, zIndex: true,
        enableEdgeHoverEvents: true,
        // 悬停药丸（深色背景 + 节点色边框 + 光晕环）
        defaultDrawNodeHover: function(context, data, settings){
          var label = data.label; if(!label) return;
          var size = settings.labelSize || 12, font = settings.labelFont || '-apple-system, sans-serif', weight = settings.labelWeight || '600';
          context.font = weight + ' ' + size + 'px ' + font;
          var textWidth = context.measureText(label).width;
          var nodeSize = data.size || 8, x = data.x, y = data.y - nodeSize - 10;
          var paddingX = 8, paddingY = 5, height = size + paddingY*2, width = textWidth + paddingX*2, radius = 4;
          context.fillStyle = '#ffffff';
          context.beginPath(); context.roundRect(x - width/2, y - height/2, width, height, radius); context.fill();
          context.strokeStyle = data.color || '#6366f1'; context.lineWidth = 2; context.stroke();
          context.fillStyle = '#1a1a2e'; context.textAlign = 'center'; context.textBaseline = 'middle'; context.fillText(label, x, y);
          context.beginPath(); context.arc(data.x, data.y, nodeSize + 4, 0, Math.PI*2);
          context.strokeStyle = data.color || '#6366f1'; context.lineWidth = 2; context.globalAlpha = 0.5; context.stroke(); context.globalAlpha = 1;
        },
        // 选中节点：邻居高亮放大、非邻居变暗缩小
        nodeReducer: function(node, data){
          var res = Object.assign({}, data);
          if (!selectedNode) return res;
          if (node === selectedNode){ res.size = (data.size||8)*1.8; res.zIndex = 2; res.highlighted = true; }
          else {
            var isNeighbor = graph.hasEdge(node, selectedNode) || graph.hasEdge(selectedNode, node);
            if (isNeighbor){ res.size = (data.size||8)*1.3; res.zIndex = 1; }
            else { res.color = dimColor(data.color, 0.2); res.size = (data.size||8)*0.5; res.zIndex = 0; }
          }
          return res;
        },
        edgeReducer: function(edge, data){
          var res = Object.assign({}, data);
          if (!selectedNode) return res;
          var s = graph.source(edge), t = graph.target(edge);
          if (s !== selectedNode && t !== selectedNode){ res.color = dimColor(data.color, 0.35); res.size = (data.size||1)*0.4; }
          return res;
        }
      });
      renderer.on('clickNode', function(p){ selectedNode = p.node; var nd = graph.getNodeAttributes(p.node); showNode(p.node, nd); renderer.refresh(); });
      renderer.on('clickEdge', function(p){ var a = graph.getEdgeAttributes(p.edge); showEdge(graph.source(p.edge), graph.target(p.edge), a.label); });
      renderer.on('clickStage', function(){ selectedNode = null; preview.style.display = 'none'; renderer.refresh(); });
      container.dataset.engine = 'sigma';
    }

    // sigma.js v3 经 esm.sh 加载（唯一引擎，无 vis 回退）
    Promise.all([
      import('https://esm.sh/sigma@3'),
      import('https://esm.sh/sigma@3/rendering'),
      import('https://esm.sh/graphology@0.25'),
      import('https://esm.sh/graphology-layout-forceatlas2@0.10'),
      import('https://esm.sh/graphology-layout-noverlap@0.4')
    ]).then(function(mods){
      var Sigma = mods[0].default;
      var R = mods[1];
      var Graph = mods[2].default;
      var forceAtlas2 = mods[3].default;
      var noverlap = mods[4].default;
      renderSigma(Sigma, Graph, forceAtlas2, noverlap, R.EdgeArrowProgram, R.NodeCircleProgram);
    }).catch(function(err){
      console.error('sigma 加载失败', err);
      document.getElementById('graph').innerHTML = '<div style="padding:40px;color:#666;font-family:sans-serif">无法加载图渲染引擎 sigma.js（需联网经 esm.sh 加载）。</div>';
    });
  </script>
</body>
</html>
HTMLEOF

echo "图谱已生成: $OUTPUT"

# --- 打开浏览器 ---
# file:// 直接打开。sigma 经 esm.sh 加载，esm.sh 发送 CORS 头，浏览器允许跨源 ESM import
# （Playwright 实测 file:// 下 engine=sigma、canvas 渲染成功、无 console error）。
if [ "$(uname)" = "Darwin" ]; then
  open "$OUTPUT"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$OUTPUT"
else
  echo "请手动打开: $OUTPUT"
fi
