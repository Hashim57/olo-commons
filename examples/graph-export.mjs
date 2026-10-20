// examples/graph-export.mjs
// Export the whole Commons graph (atoms + links) to GraphML for Gephi, or JSON
// for NetworkX / d3. Pages through the public export functions with the anon key.
//   node examples/graph-export.mjs graphml > olo.graphml
//   node examples/graph-export.mjs json > olo.json
import { writeFileSync } from 'node:fs';

const URL = 'https://bfldflbkebyapfagsxnr.supabase.co/rest/v1/rpc/';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJmbGRmbGJrZWJ5YXBmYWdzeG5yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ3Mjc2MzksImV4cCI6MjA5MDMwMzYzOX0.fi5Kvn9CoikPFJ4RkUnJ2hmAGUVGXFkeT00DfjxLuQQ'; // public read key
const call = async (fn, body) => (await fetch(URL + fn, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: ANON, Authorization: 'Bearer ' + ANON }, body: JSON.stringify(body) })).json();

async function page(fn, key, limit) { const out = []; let after = '1970-01-01'; for (;;) { const r = await call(fn, { p_after: after, p_limit: limit }); out.push(...r[key]); if (!r.next_after || r[key].length < limit) break; after = r.next_after; } return out; }
const atoms = await page('olo_export', 'atoms', 500), links = await page('olo_links_export', 'links', 2000);
const fmt = process.argv[2] || 'json';
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
if (fmt === 'graphml') {
  const g = ['<?xml version="1.0" encoding="UTF-8"?>', '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">', '<key id="title" for="node" attr.name="title" attr.type="string"/><key id="source" for="node" attr.name="source" attr.type="string"/><key id="url" for="node" attr.name="url" attr.type="string"/><key id="w" for="edge" attr.name="weight" attr.type="double"/>', '<graph edgedefault="directed">'];
  for (const a of atoms) g.push(`<node id="${a.id}"><data key="title">${esc(a.title)}</data><data key="source">${esc(a.source)}</data><data key="url">${esc(a.url)}</data></node>`);
  for (const l of links) g.push(`<edge source="${l.from}" target="${l.to}"><data key="w">${l.weight}</data></edge>`);
  g.push('</graph></graphml>'); process.stdout.write(g.join('\n'));
} else process.stdout.write(JSON.stringify({ atoms, links, licence: 'Compilation CC BY-SA 4.0; each atom under its own licence' }));
console.error(`${atoms.length} atoms, ${links.length} links`);
