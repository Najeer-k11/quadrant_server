// Builds a standalone HTML report from two runs of benchmark/run.dart.
//
//   dart run benchmark/report.dart [--before=baseline] [--after=final]
//
// Writes benchmark/results/report.html, which needs no network access.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  String option(String name, String fallback) {
    final prefix = '--$name=';
    for (final arg in args) {
      if (arg.startsWith(prefix)) return arg.substring(prefix.length);
    }
    return fallback;
  }

  Object? load(String label) =>
      jsonDecode(File('benchmark/results/$label.json').readAsStringSync());

  final data = jsonEncode({
    'before': load(option('before', 'baseline')),
    'after': load(option('after', 'final')),
  }).replaceAll('</', r'<\/'); // Must not close the <script> it is embedded in.

  const out = 'benchmark/results/report.html';
  File(out).writeAsStringSync(_template.replaceFirst('/*DATA*/null', data));
  print('Wrote $out');
}

const _template = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>QuadrantServer benchmark results</title>
<style>
  :root {
    color-scheme: light;
    --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e;
    --muted: #898781; --grid: #e1e0d9; --axis: #c3c2b7;
    --border: rgba(11,11,11,0.10);
    --s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a;
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7;
      --muted: #898781; --grid: #2c2c2a; --axis: #383835;
      --border: rgba(255,255,255,0.10);
      --s1: #3987e5; --s2: #d95926; --s3: #199e70;
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --ink: #f0efec; --ink-2: #c3c2b7;
    --muted: #898781; --grid: #2c2c2a; --axis: #383835;
    --border: rgba(255,255,255,0.10);
    --s1: #3987e5; --s2: #d95926; --s3: #199e70;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--page); color: var(--ink);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  main { max-width: 900px; margin: 0 auto; padding: 32px 20px 56px; }
  h1 { font-size: 24px; font-weight: 600; margin: 0 0 4px; }
  h2 { font-size: 16px; font-weight: 600; margin: 0; }
  .sub { color: var(--ink-2); margin: 0; }
  .tiles {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
    gap: 12px; margin: 24px 0;
  }
  .tile, .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px;
  }
  .tile { padding: 16px; }
  .tile .label { color: var(--ink-2); font-size: 13px; }
  .tile .value { font-size: 28px; font-weight: 600; margin-top: 2px; }
  .tile .note { color: var(--ink-2); font-size: 13px; }
  .card { padding: 20px; margin-bottom: 16px; position: relative; }
  .legend {
    display: flex; flex-wrap: wrap; gap: 16px; margin: 12px 0 4px;
    color: var(--ink-2); font-size: 13px;
  }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .key-bar { width: 12px; height: 12px; border-radius: 3px; }
  .key-line { width: 16px; height: 2px; border-radius: 1px; }
  svg { display: block; width: 100%; height: auto; }
  svg text { font-family: inherit; }
  .tick { font-size: 12px; fill: var(--muted); font-variant-numeric: tabular-nums; }
  .label-text { font-size: 13px; fill: var(--ink-2); }
  .strong-text { font-size: 13px; fill: var(--ink); font-weight: 600; }
  .hit { fill: transparent; outline: none; cursor: default; }
  .hit:focus-visible { stroke: var(--ink-2); stroke-width: 1; }
  .bar { transition: opacity 80ms; }
  .row:hover .bar, .row:focus-within .bar { opacity: .75; }
  .caption { color: var(--ink-2); font-size: 13px; margin: 10px 0 0; }
  details { margin-top: 12px; font-size: 13px; }
  summary { cursor: pointer; color: var(--ink-2); }
  .scroll { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px; }
  th, td { padding: 5px 10px; border-bottom: 1px solid var(--grid); text-align: right; white-space: nowrap; }
  th:first-child, td:first-child { text-align: left; }
  th { font-weight: 600; color: var(--ink-2); }
  td { font-variant-numeric: tabular-nums; }
  #tip {
    position: fixed; pointer-events: none; display: none; z-index: 10;
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 6px; padding: 8px 10px; font-size: 13px;
    box-shadow: 0 2px 10px rgba(0,0,0,.14);
  }
  #tip .title { color: var(--ink-2); margin-bottom: 4px; }
  #tip .tip-row { display: flex; align-items: center; gap: 8px; }
  #tip .tip-row b { font-weight: 600; font-variant-numeric: tabular-nums; }
  #tip .tip-row span:last-child { color: var(--ink-2); }
  ul { margin: 8px 0 0; padding-left: 20px; color: var(--ink-2); font-size: 14px; }
  li { margin-bottom: 4px; }
</style>
</head>
<body>
<main>
  <h1>QuadrantServer benchmark results</h1>
  <p class="sub" id="meta"></p>
  <div class="tiles" id="tiles"></div>

  <section class="card">
    <h2>Heavier paths got much faster on one isolate; simple routes got slightly slower</h2>
    <p class="caption">Requests per second, one isolate, before and after this branch. Longer is better.</p>
    <div class="legend" id="legend-a"></div>
    <div id="chart-a"></div>
    <details><summary>Show as a table</summary><div class="scroll" id="table-a"></div></details>
  </section>

  <section class="card">
    <h2>Isolates help most when handlers do real work</h2>
    <p class="caption">Speed-up compared with one isolate, in <code>QuadrantCluster</code>. The server had 4 physical cores (8 hardware threads). The rate limit was not measured at 2 isolates.</p>
    <div class="legend" id="legend-b"></div>
    <div id="chart-b"></div>
    <details><summary>Show as a table</summary><div class="scroll" id="table-b"></div></details>
  </section>

  <section class="card">
    <h2>The framework is a small part of each request's cost</h2>
    <p class="caption">Server CPU time per plain request, from the baseline run. Shorter is better. The C++ and socket servers do not parse HTTP or run a framework, so they are best cases rather than achievable targets.</p>
    <div id="chart-c"></div>
    <details><summary>Show as a table</summary><div class="scroll" id="table-c"></div></details>
  </section>

  <section class="card">
    <h2>How to read these numbers</h2>
    <ul>
      <li>Measured on an i7-13620H laptop with a compiled build over loopback, with 64 keep-alive connections and no TLS. Your hardware and workload will differ.</li>
      <li>Each figure is the median of three 6-second runs. Most runs varied by under 5%, so treat smaller differences as noise.</li>
      <li>The plain routes are close to doing nothing, so they show the most overhead. Handlers that do real work will see smaller differences between before and after.</li>
      <li>The load generator runs on the same machine. It reached about 400,000 req/s against the bare C++ server, well above every Dart result here, so it should not be what limits those. That C++ server was held back by it, though, which is why this page compares it by CPU time.</li>
    </ul>
  </section>
</main>
<div id="tip" role="status"></div>
<script>
const DATA = /*DATA*/null;
if (location.hash === '#dark') document.documentElement.dataset.theme = 'dark';

const NS = 'http://www.w3.org/2000/svg';
const row = (set, id) => DATA[set].results.find(r => r.id === id);
const num = n => Math.round(n).toLocaleString('en-US');
const compact = n => n >= 1000 ? (n / 1000) + 'K' : String(n);
const x1 = n => n.toFixed(1) + 'x';
const pct = (a, b) => {
  const change = (b / a - 1) * 100;
  return (change >= 0 ? '+' : '−') + Math.abs(change).toFixed(0) + '%';
};

function el(tag, attrs, parent, text) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  if (text !== undefined) node.textContent = text;
  if (parent) parent.appendChild(node);
  return node;
}

function html(tag, parent, text, cls) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  if (parent) parent.appendChild(node);
  return node;
}

// ─── Tooltip ─────────────────────────────────────────────────
const tip = document.getElementById('tip');

function showTip(x, y, title, rows) {
  tip.replaceChildren();
  html('div', tip, title, 'title');
  for (const r of rows) {
    const line = html('div', tip, undefined, 'tip-row');
    if (r.color) {
      const key = html('span', line, undefined, 'key-line');
      key.style.background = r.color;
    }
    html('b', line, r.value);
    html('span', line, r.label);
  }
  tip.style.display = 'block';
  const box = tip.getBoundingClientRect();
  const left = Math.min(x + 14, innerWidth - box.width - 8);
  const top = Math.min(y + 14, innerHeight - box.height - 8);
  tip.style.left = Math.max(8, left) + 'px';
  tip.style.top = Math.max(8, top) + 'px';
}
const hideTip = () => { tip.style.display = 'none'; };

function hover(node, title, rows, onEnter, onLeave) {
  node.setAttribute('tabindex', '0');
  node.setAttribute('aria-label', title + ': ' +
      rows.map(r => r.label + ' ' + r.value).join(', '));
  node.addEventListener('pointermove', e => {
    onEnter && onEnter();
    showTip(e.clientX, e.clientY, title, rows);
  });
  node.addEventListener('pointerleave', () => { hideTip(); onLeave && onLeave(); });
  node.addEventListener('focus', () => {
    onEnter && onEnter();
    const b = node.getBoundingClientRect();
    showTip(b.left + b.width / 2, b.top + b.height / 2, title, rows);
  });
  node.addEventListener('blur', () => { hideTip(); onLeave && onLeave(); });
}

// A bar with a 4px rounded end, square where it meets the baseline.
function barPath(x, y, w, h) {
  const r = Math.min(4, w, h / 2);
  return `M${x} ${y}h${w - r}a${r} ${r} 0 0 1 ${r} ${r}v${h - 2 * r}` +
      `a${r} ${r} 0 0 1 ${-r} ${r}h${r - w}z`;
}

function legend(id, items) {
  const box = document.getElementById(id);
  for (const item of items) {
    const span = html('span', box);
    const key = html('i', span, undefined, item.line ? 'key-line' : 'key-bar');
    key.style.background = item.color;
    span.appendChild(document.createTextNode(item.label));
  }
}

function table(id, headers, rows) {
  const t = html('table', document.getElementById(id));
  const head = html('tr', html('thead', t));
  headers.forEach(h => html('th', head, h));
  const body = html('tbody', t);
  rows.forEach(r => {
    const tr = html('tr', body);
    r.forEach(c => html('td', tr, c));
  });
}

// ─── Header ──────────────────────────────────────────────────
const stackAfter = row('after', 'q_stack/i1/c64').rps;
const stack8 = row('after', 'qc_stack/i8/c64').rps;
const routesBefore = row('before', 'q_param100/i1/c64').rps;
const routesAfter = row('after', 'q_param100/i1/c64').rps;
const cpu1 = row('after', 'q_cpu1ms/i1/c64').rps;
const cpu8 = row('after', 'qc_cpu1ms/i8/c64').rps;

document.getElementById('meta').textContent =
    'Before: main branch. After: feat/performance-and-fixes. Run on ' +
    new Date(DATA.after.date).toLocaleDateString('en-GB',
        {day: 'numeric', month: 'long', year: 'numeric'}) + '.';

const tiles = document.getElementById('tiles');
[
  ['Typical stack on 8 isolates', compact(Math.round(stack8 / 100) * 100) + ' req/s',
    x1(stack8 / stackAfter) + ' the ' + num(stackAfter) + ' req/s of one isolate'],
  ['100-route app, one isolate', pct(routesBefore, routesAfter),
    num(routesBefore) + ' → ' + num(routesAfter) + ' req/s'],
  ['1 ms handlers on 8 isolates', x1(cpu8 / cpu1),
    num(cpu1) + ' → ' + num(cpu8) + ' req/s'],
].forEach(([label, value, note]) => {
  const tile = html('div', tiles, undefined, 'tile');
  html('div', tile, label, 'label');
  html('div', tile, value, 'value');
  html('div', tile, note, 'note');
});

const css = name => `var(--${name})`;

// ─── Chart A: before and after ───────────────────────────────
(function () {
  const scenarios = [
    ['q_param100/i1/c64', '100 routes, matching the last'],
    ['q_stack/i1/c64', 'Typical middleware stack'],
    ['q_requestid/i1/c64', 'requestId() only'],
    ['q_json/i1/c64', 'JSON response'],
    ['q_plain/i1/c64', 'Plain text response'],
    ['q_post_json/i1/c64', '1 KB JSON POST'],
  ].map(([id, name]) => ({
    name, before: row('before', id).rps, after: row('after', id).rps,
  })).sort((a, b) => b.after / b.before - a.after / a.before);

  legend('legend-a', [
    {label: 'Before', color: css('s1')},
    {label: 'After', color: css('s2')},
  ]);

  const W = 860, left = 210, right = 70, barH = 12, gap = 2, rowH = 42, top = 8;
  const H = top + scenarios.length * rowH + 26;
  const maxValue = 80000;
  const scale = v => (W - left - right) * v / maxValue;
  const svg = el('svg', {viewBox: `0 0 ${W} ${H}`, role: 'group',
      'aria-label': 'Requests per second before and after, by scenario'},
      document.getElementById('chart-a'));

  for (let v = 0; v <= maxValue; v += 20000) {
    const x = left + scale(v);
    el('line', {x1: x, x2: x, y1: top, y2: H - 22,
        stroke: v === 0 ? css('axis') : css('grid'), 'stroke-width': 1}, svg);
    el('text', {x, y: H - 6, 'text-anchor': 'middle', class: 'tick'}, svg, compact(v));
  }

  scenarios.forEach((s, i) => {
    const y = top + i * rowH + (rowH - (2 * barH + gap)) / 2;
    const g = el('g', {class: 'row'}, svg);
    el('text', {x: left - 12, y: y + barH + 5, 'text-anchor': 'end',
        class: 'label-text'}, g, s.name);
    el('path', {d: barPath(left, y, scale(s.before), barH), class: 'bar',
        fill: css('s1')}, g);
    el('path', {d: barPath(left, y + barH + gap, scale(s.after), barH),
        class: 'bar', fill: css('s2')}, g);
    el('text', {x: W - 4, y: y + barH + 5, 'text-anchor': 'end',
        class: 'strong-text'}, g, pct(s.before, s.after));
    const hit = el('rect', {x: 0, y: top + i * rowH, width: W, height: rowH,
        class: 'hit'}, g);
    hover(hit, s.name, [
      {color: css('s1'), value: num(s.before) + ' req/s', label: 'Before'},
      {color: css('s2'), value: num(s.after) + ' req/s', label: 'After'},
      {value: pct(s.before, s.after), label: 'Change'},
    ]);
  });

  table('table-a', ['Scenario', 'Before (req/s)', 'After (req/s)', 'Change'],
      scenarios.map(s => [s.name, num(s.before), num(s.after), pct(s.before, s.after)]));
})();

// ─── Chart B: scaling ────────────────────────────────────────
(function () {
  const lines = [
    {
      name: '1 ms of CPU work', color: css('s1'), line: true,
      points: [[1, row('after', 'q_cpu1ms/i1/c64').rps],
        ...[2, 4, 8].map(n => [n, row('after', `qc_cpu1ms/i${n}/c64`).rps])],
    },
    {
      name: 'Plain route', color: css('s2'), line: true,
      points: [1, 2, 4, 8].map(n => [n, row('after', `qc_plain/i${n}/c64`).rps]),
    },
    {
      name: 'Shared rate limit', color: css('s3'), line: true,
      points: [1, 4, 8].map(n => [n, row('after', `qc_ratelimit/i${n}/c64`).rps]),
    },
  ];
  lines.forEach(l => {
    const base = l.points[0][1];
    l.points = l.points.map(([n, rps]) => ({n, rps, speedup: rps / base}));
  });

  legend('legend-b', [
    ...lines.map(l => ({label: l.name, color: l.color, line: true})),
    {label: 'Perfect scaling', color: css('axis'), line: true},
  ]);

  const W = 860, H = 340, left = 44, right = 170, top = 12, bottom = 44;
  const px = n => left + (W - left - right) * (n - 1) / 7;
  const py = v => top + (H - top - bottom) * (1 - v / 8);
  const svg = el('svg', {viewBox: `0 0 ${W} ${H}`, role: 'group',
      'aria-label': 'Speed-up by number of isolates'},
      document.getElementById('chart-b'));

  for (const v of [0, 2, 4, 6, 8]) {
    el('line', {x1: left, x2: W - right, y1: py(v), y2: py(v),
        stroke: v === 0 ? css('axis') : css('grid'), 'stroke-width': 1}, svg);
    el('text', {x: left - 8, y: py(v) + 4, 'text-anchor': 'end', class: 'tick'},
        svg, v + 'x');
  }
  for (const n of [1, 2, 4, 8]) {
    el('text', {x: px(n), y: H - bottom + 18, 'text-anchor': 'middle',
        class: 'tick'}, svg, String(n));
  }
  el('text', {x: left + (W - left - right) / 2, y: H - 6, 'text-anchor': 'middle',
      class: 'tick'}, svg, 'Isolates');

  el('line', {x1: px(1), y1: py(1), x2: px(8), y2: py(8), stroke: css('axis'),
      'stroke-width': 2, 'stroke-linecap': 'round'}, svg);

  for (const l of lines) {
    el('polyline', {
      points: l.points.map(p => `${px(p.n)},${py(p.speedup)}`).join(' '),
      fill: 'none', stroke: l.color, 'stroke-width': 2,
      'stroke-linejoin': 'round', 'stroke-linecap': 'round',
    }, svg);
    for (const p of l.points) {
      el('circle', {cx: px(p.n), cy: py(p.speedup), r: 4, fill: l.color,
          stroke: css('surface'), 'stroke-width': 2}, svg);
    }
  }

  // End labels. The two lower lines finish almost together, so their labels
  // sit apart with leader lines back to the points.
  const endY = i => py(lines[i].points.at(-1).speedup);
  const labelYs = [endY(0) + 4, Math.min(endY(1), endY(2)) - 10,
      Math.max(endY(1), endY(2)) + 18];
  lines.forEach((l, i) => {
    const end = l.points.at(-1);
    const labelX = px(8) + 26;
    const y = labelYs[i];
    el('line', {x1: px(8) + 6, y1: py(end.speedup), x2: labelX - 4, y2: y - 4,
        stroke: css('axis'), 'stroke-width': 1}, svg);
    el('text', {x: labelX, y, class: 'strong-text'}, svg, x1(end.speedup));
    el('text', {x: labelX + 36, y, class: 'label-text'}, svg,
        i === 0 ? 'CPU work' : i === 1 ? 'Plain' : 'Rate limit');
  });

  // Crosshair: snaps to the nearest measured isolate count.
  const cross = el('line', {y1: top, y2: H - bottom, stroke: css('axis'),
      'stroke-width': 1, visibility: 'hidden'}, svg);
  const edges = [1, 2, 4, 8];
  edges.forEach((n, i) => {
    const from = i === 0 ? left : (px(edges[i - 1]) + px(n)) / 2;
    const to = i === 3 ? W - right : (px(n) + px(edges[i + 1])) / 2;
    const hit = el('rect', {x: from, y: top, width: to - from, height: H - top - bottom,
        class: 'hit'}, svg);
    const rows = lines.flatMap(l => {
      const p = l.points.find(q => q.n === n);
      return p ? [{color: l.color, value: x1(p.speedup),
        label: `${l.name} (${num(p.rps)} req/s)`}] : [];
    });
    hover(hit, `${n} isolate${n > 1 ? 's' : ''}`, rows, () => {
      cross.setAttribute('x1', px(n));
      cross.setAttribute('x2', px(n));
      cross.setAttribute('visibility', 'visible');
    }, () => cross.setAttribute('visibility', 'hidden'));
  });

  const cell = (l, n) => {
    const p = l.points.find(q => q.n === n);
    return p ? `${num(p.rps)} (${x1(p.speedup)})` : 'not measured';
  };
  const stackRow = ['Typical stack',
    `${num(row('after', 'q_stack/i1/c64').rps)} (1.0x)`, 'not measured', 'not measured',
    `${num(row('after', 'qc_stack/i8/c64').rps)} (${x1(row('after', 'qc_stack/i8/c64').rps / row('after', 'q_stack/i1/c64').rps)})`];
  table('table-b', ['Workload, req/s', '1', '2', '4', '8'], [
    ...lines.map(l => [l.name, ...[1, 2, 4, 8].map(n => cell(l, n))]),
    stackRow,
  ]);
})();

// ─── Chart C: cost by layer ──────────────────────────────────
(function () {
  const layers = [
    ['cpp_epoll/i1/c64', 'Bare C++ epoll server'],
    ['dart_socket/i1/c64', 'Dart sockets'],
    ['dartio_plain/i1/c64', 'dart:io HTTP'],
    ['q_plain/i1/c64', 'QuadrantServer'],
  ].map(([id, name]) => ({name, us: 1e6 / row('before', id).rpsPerCore}));

  const W = 860, left = 210, right = 90, barH = 20, rowH = 38, top = 6;
  const H = top + layers.length * rowH + 4;
  const maxUs = Math.max(...layers.map(l => l.us));
  const scale = v => (W - left - right) * v / maxUs;
  const svg = el('svg', {viewBox: `0 0 ${W} ${H}`, role: 'group',
      'aria-label': 'CPU time per request by layer'},
      document.getElementById('chart-c'));

  el('line', {x1: left, x2: left, y1: top, y2: H - 4, stroke: css('axis'),
      'stroke-width': 1}, svg);
  layers.forEach((l, i) => {
    const y = top + i * rowH + (rowH - barH) / 2;
    const g = el('g', {class: 'row'}, svg);
    el('text', {x: left - 12, y: y + 15, 'text-anchor': 'end', class: 'label-text'},
        g, l.name);
    el('path', {d: barPath(left, y, scale(l.us), barH), class: 'bar',
        fill: css('s1')}, g);
    el('text', {x: left + scale(l.us) + 8, y: y + 15, class: 'strong-text'}, g,
        l.us.toFixed(1) + ' µs');
    const hit = el('rect', {x: 0, y: top + i * rowH, width: W, height: rowH,
        class: 'hit'}, g);
    hover(hit, l.name, [{color: css('s1'), value: l.us.toFixed(1) + ' µs',
      label: 'CPU per request'}]);
  });

  table('table-c', ['Layer', 'CPU per request'],
      layers.map(l => [l.name, l.us.toFixed(1) + ' µs']));
})();
</script>
</body>
</html>
''';
