#!/usr/bin/env node
// Smoke-test intake server — the "wake-on-save" half of the manual smoke-test loop.
//
// Serves a /smoke-form HTML page and COLLECTS the tester's per-item results as append-only
// JSONL, so a Monitor (`tail -f <form>.results.jsonl`) can wake the driving agent the instant a
// FAIL/issue lands — turning "fill the form, then paste results back" into a hands-off loop that
// files GitHub issues in real time as the tester goes.
//
// The form POSTs each result ONLY when it's served from here (same-origin, online mode). Opened
// straight from `file://` it degrades to localStorage + Copy-Results (offline), so the form stays
// a self-contained artifact either way. Generic + dependency-free → reusable across projects
// (destined for skill-templates alongside /smoke-form).
//
// Usage:
//   node tools/smoke-intake.mjs <form.html> [--port 8770]
//     → serves the form at http://127.0.0.1:<port>/ and appends results to <form>.results.jsonl
//     → watch live with:  tail -f "<form>.results.jsonl"
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// Form path: an explicit arg, else the newest docs/smoke-{test,form}-*.html (so `npm run
// smoke-intake` just works after generating a report).
function newestForm() {
  try {
    const dir = 'docs';
    const files = fs.readdirSync(dir)
      .filter((f) => /^smoke-(test|form)-.*\.html$/.test(f))
      .map((f) => ({ f: path.join(dir, f), m: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.m - a.m);
    return files[0]?.f || null;
  } catch { return null; }
}
const argForm = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : null;
const formPath = argForm || newestForm();
if (!formPath || !fs.existsSync(formPath)) {
  console.error('usage: node tools/smoke-intake.mjs [form.html] [--port N]  (defaults to the newest docs/smoke-*.html)');
  process.exit(1);
}
const portFlag = process.argv.indexOf('--port');
const PORT = portFlag >= 0 ? Number(process.argv[portFlag + 1]) : Number(process.env.SMOKE_PORT || 8770);
const resultsPath = formPath.replace(/\.html?$/i, '') + '.results.jsonl';

const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'GET' && url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    fs.createReadStream(formPath).pipe(res);
    return;
  }
  // The current results, for the agent to read on demand (the Monitor tails the file directly).
  if (req.method === 'GET' && url === '/results.jsonl') {
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson; charset=utf-8' });
    res.end(fs.existsSync(resultsPath) ? fs.readFileSync(resultsPath) : '');
    return;
  }
  // A single item's result (or a status change). Appended verbatim + a receivedAt stamp.
  if (req.method === 'POST' && url === '/result') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', () => {
      let rec;
      try { rec = JSON.parse(body); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }
      rec.receivedAt = new Date().toISOString();
      fs.appendFileSync(resultsPath, JSON.stringify(rec) + '\n');
      // stdout doubles as a human log; the Monitor watches the file, not this.
      console.log(`[intake] ${String(rec.status || '?').toUpperCase().padEnd(4)} ${rec.id || ''}  ${rec.title || ''}${rec.notes ? '  — ' + rec.notes : ''}`);
      json(res, 200, { ok: true });
    });
    return;
  }
  json(res, 404, { ok: false, error: 'not found' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[intake] serving ${path.basename(formPath)}  →  http://127.0.0.1:${PORT}/`);
  console.log(`[intake] results  →  ${resultsPath}`);
  console.log('[intake] open the URL in a browser; mark items and they stream here live.');
});
