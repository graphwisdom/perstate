#!/usr/bin/env node
// tests/view-render-bench.mjs — 浏览器侧 view 渲染耗时基准（需 playwright + 系统 Chrome）
// 用法：
//   1) 生成 HTML：bash scripts/perstate-view.sh --worktree <wt> --session-id bench --output /tmp/view.html
//   2) 起 http：cd /tmp && python3 -m http.server 8753 --bind 127.0.0.1 &
//   3) 跑：node tests/view-render-bench.mjs http://localhost:8753/view.html
//
// 基线（headless Chrome, florian 2208 实体图）：
//   before (vis-network, cap 1000): median 24040ms
//   after  (sigma.js v3,    full 2208): median 4361ms   → 5.5x faster, 2.2x nodes, ~12x per-node
import { chromium } from 'playwright';

const EXEC = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const url = process.argv[2];
const RUNS = 3;
if (!url) { console.error('用法: node view-render-bench.mjs <http-url>'); process.exit(1); }

const browser = await chromium.launch({ headless: true, executablePath: EXEC });
const times = [];
for (let i = 0; i < RUNS; i++) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  const t0 = Date.now();
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const g = document.getElementById('graph');
    return g && g.dataset.engine && g.querySelector('canvas');
  }, { timeout: 60000 });
  const t1 = Date.now();
  times.push(t1 - t0);
  console.log(`run${i+1}: ${t1 - t0}ms`);
  await ctx.close();
}
times.sort((a, b) => a - b);
console.log(`=> min=${times[0]}ms median=${times[Math.floor(RUNS / 2)]}ms`);
await browser.close();
