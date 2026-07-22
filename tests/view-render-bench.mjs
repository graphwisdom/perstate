#!/usr/bin/env node
// tests/view-render-bench.mjs — 浏览器侧 view 渲染耗时基准（需 playwright + 系统 Chrome）
// 用法：
//   1) 生成 HTML：bash scripts/perstate-view.sh --worktree <wt> --session-id bench --output /tmp/view.html
//   2) 跑：node tests/view-render-bench.mjs file:///tmp/view.html
//
// 公平测法：等待 canvas 出现 + 图稳定可交互
//   - sigma: FA2 同步算完，canvas 出现即稳定
//   - vis:   等待 stabilizationIterationsDone 事件（barnesHut 异步迭代）
//
// 基线（headless Chrome, florian 2208 实体图）：
//   before (vis-network, cap 1000): median 24695ms  (含 stabilization ~22s)
//   after  (sigma.js v3,    full 2208): median 4650ms
//   → 5.3x faster, 2.2x nodes, ~11.7x per-node
import { chromium } from 'playwright';

const EXEC = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const url = process.argv[2];
const RUNS = 3;
if (!url) { console.error('用法: node view-render-bench.mjs <url>'); process.exit(1); }

const browser = await chromium.launch({ headless: true, executablePath: EXEC });
const times = [];
for (let i = 0; i < RUNS; i++) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  const t0 = Date.now();
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const g = document.getElementById('graph');
    return g && g.querySelector('canvas');
  }, { timeout: 120000 });
  // wait for layout to stabilize
  await page.evaluate(() => new Promise((resolve) => {
    const g = document.getElementById('graph');
    if (g.dataset.engine === 'sigma') { resolve(); return; }
    if (typeof network !== 'undefined' && network.on) {
      network.on('stabilizationIterationsDone', resolve);
      if (network.physics && !network.physics.physicsEnabled) resolve();
    } else { resolve(); }
  }));
  const t1 = Date.now();
  times.push(t1 - t0);
  console.log(`run${i+1}: ${t1 - t0}ms`);
  await ctx.close();
}
times.sort((a, b) => a - b);
console.log(`=> min=${times[0]}ms median=${times[Math.floor(RUNS / 2)]}ms`);
await browser.close();
