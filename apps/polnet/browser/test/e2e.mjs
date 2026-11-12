// End-to-end test of the real browser: Electron launched through Playwright, against the POL Net dev API
// (Deno, server/scripts/dev.ts) and a local test site. Needs a display (xvfb-run on Linux) and deno.
//   xvfb-run -a node test/e2e.mjs
import { _electron as electron } from "playwright";
import { spawn } from "node:child_process";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { verifyHumanPass } from "../../trust/polnet-trust.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const serverDir = path.resolve(root, "..", "server");
const API_PORT = 8799;
const API = `http://localhost:${API_PORT}`;
const results = [];
const check = async (name, fn) => {
  try {
    await fn();
    results.push(["PASS", name]);
    console.log(`  PASS  ${name}`);
  } catch (e) {
    results.push(["FAIL", name, e]);
    console.log(`  FAIL  ${name}\n        ${e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n        ") : e}`);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- The dev API -------------------------------------------------------------------------------------
const deno = spawn(process.env.DENO || "deno", ["run", "-A", "scripts/dev.ts"], { cwd: serverDir, env: { ...process.env, PORT: String(API_PORT) }, stdio: ["ignore", "pipe", "inherit"] });
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error("dev API did not start")), 60_000);
  deno.stdout.on("data", (d) => { if (String(d).includes("listening")) { clearTimeout(t); resolve(); } });
});
const api = async (method, p, body, token) => {
  const r = await fetch(`${API}${p}`, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: r.status, ...(await r.json()) };
};

// --- A local site: a page with trackers on it, and a members-only page behind pol:// -----------------
let lastVisitHeader = null;
const NONCE = "e2e-nonce-12345";
const site = http.createServer((req, res) => {
  const me = `http://127.0.0.1:${site.address().port}`;
  if (req.url.startsWith("/support")) {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Security alert</title><h1>WARNING: Your computer has been infected with a Trojan</h1><p>Do not close this window. Call Microsoft Support on +1 (888) 555-0199 now.</p>`);
  }
  if (req.url.startsWith("/login")) {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Sign in</title><form><input name="user"><input type="password" name="pw"></form>`);
  }
  if (req.url.startsWith("/verify-other")) {
    const q = new URLSearchParams({ origin: "https://shop.example", return: "https://shop.example/cb", nonce: NONCE });
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Other</title><a id="prove" href="polnet://human/?${q}">Prove</a>`);
  }
  if (req.url.startsWith("/verify")) {
    const q = new URLSearchParams({ origin: me, return: `${me}/verified`, nonce: NONCE });
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Verify</title><a id="prove" href="polnet://human/?${q}">Show I am a real person with POL Net</a>`);
  }
  if (req.url.startsWith("/verified")) {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Thanks</title><p id="v">verified page</p>`);
  }
  if (req.url.startsWith("/members")) {
    lastVisitHeader = req.headers["x-polnet-visit"] || null;
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(`<!doctype html><title>Garden members</title><h1 id="h">Welcome to the community garden</h1><a id="next" href="events">Events</a>`);
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>Tracker test</title><h1>News</h1>
    <img src="https://www.google-analytics.com/collect?v=1">
    <img src="https://stats.g.doubleclick.net/r/collect">
    <script src="https://connect.facebook.net/en_US/fbevents.js"></script>
    <p id="ok">loaded</p>`);
});
await new Promise((r) => site.listen(0, "127.0.0.1", r));
const SITE = `http://127.0.0.1:${site.address().port}`;

// --- The browser --------------------------------------------------------------------------------------
const userData = fs.mkdtempSync(path.join(os.tmpdir(), "polnet-e2e-"));
fs.writeFileSync(path.join(userData, "settings.json"), JSON.stringify({ server: API, olo: "https://olo.invalid" }));
const app = await electron.launch({
  args: [root, "--no-sandbox"],
  env: { ...process.env, POLNET_E2E: "1", POLNET_USER_DATA: userData, POLNET_HIDDEN: "1" },
  timeout: 60_000,
});

const main = (fn, arg) => app.evaluate(fn, arg);
const tabEval = (js) => main(async (_e, code) => {
  const p = global.__polnet;
  const w = [...p.windows][0];
  return p.activeTab(w).view.webContents.executeJavaScript(code, true);
}, js);
const tabUrl = () => main(() => { const p = global.__polnet; const w = [...p.windows][0]; return p.activeTab(w).view.webContents.getURL(); });
const go = (url) => main((_e, u) => { const p = global.__polnet; const w = [...p.windows][0]; p.navigate(w, p.activeTab(w), u); }, url);
const state = () => main(() => { const p = global.__polnet; return p.stateOf([...p.windows][0]); });
async function waitFor(fn, what, ms = 15_000) {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    try {
      last = await fn();
      if (last) return last;
    } catch (e) { last = e; }
    await sleep(200);
  }
  throw new Error(`timed out waiting for ${what} (last: ${last instanceof Error ? last.message : JSON.stringify(last)})`);
}

try {
  await waitFor(async () => (await main(() => global.__polnet && [...global.__polnet.windows].length)) > 0, "the window");
  await waitFor(async () => (await tabUrl()).startsWith("polnet://newtab"), "the new tab page");

  await check("the new tab page renders, and the toolbar shows one tab", async () => {
    await waitFor(async () => (await tabEval("document.querySelector('h1') && document.querySelector('h1').textContent")) === "POL Net", "new tab heading");
    assert.equal((await state()).tabs.length, 1);
  });

  await check("Shields block third-party trackers and count them", async () => {
    await go(`${SITE}/news`);
    await waitFor(async () => (await tabEval("document.getElementById('ok') && document.getElementById('ok').textContent")) === "loaded", "the test page");
    await waitFor(async () => (await state()).active.blocked >= 3, "three blocked trackers");
    assert.equal(await tabEval("typeof window.polnet"), "undefined", "ordinary pages get no bridge");
  });

  await check("tracking parameters are stripped from the address", async () => {
    await go(`${SITE}/article?id=7&utm_source=newsletter&fbclid=abc`);
    await waitFor(async () => (await tabUrl()).includes("/article"), "the article");
    const u = new URL(await tabUrl());
    assert.equal(u.searchParams.get("id"), "7");
    assert.equal(u.searchParams.get("utm_source"), null);
    assert.equal(u.searchParams.get("fbclid"), null);
  });

  await check("a lookalike of a bank or payment site is stopped with a warning before it loads", async () => {
    await go("http://paypa1-secure-login.com/");
    await waitFor(async () => (await tabUrl()).startsWith("polnet://warning"), "the warning page");
    assert.match(await tabUrl(), /kind=lookalike/);
    await waitFor(async () => /fake site/i.test(await tabEval("document.body.innerText")), "warning text");
    assert.doesNotMatch(await tabEval("document.body.innerText"), /\bnull\b/, "no stray 'null' where a protected-mode part is left out");
  });

  await check("members-only pages ask to join first", async () => {
    await go("polnet://tasks/");
    await waitFor(async () => /Join POL Net first/.test(await tabEval("document.body.innerText")), "join prompt");
    await go("pol://community-garden/");
    await waitFor(async () => /Members only/.test(await tabEval("document.body.innerText")), "members only page");
  });

  // Join: the dev API passes any Proof-of-Life token starting "dev-".
  const joined = await api("POST", "/v1/join", { pol_token: "dev-e2e-member", handle: "e2e_member" });
  const org = await api("POST", "/v1/join", { pol_token: "dev-e2e-org", handle: "e2e_org" });

  await check("a member pass from the join flow is accepted and shown in the toolbar", async () => {
    assert.ok(joined.pass, JSON.stringify(joined));
    assert.equal(await main((_e, pass) => global.__polnet.acceptPass(pass), joined.pass), true);
    await waitFor(async () => (await state()).member?.handle === "e2e_member", "member badge");
    const raw = fs.readFileSync(path.join(userData, "settings.json"), "utf8");
    // Without a keychain (Linux CI) safeStorage is unavailable and the pass is stored plain; on a Mac it is encrypted.
    assert.ok(raw.includes("e2e_member"));
  });

  await check("pol:// resolves through the members' registry and the site receives a pairwise visit pass", async () => {
    const reg = await api("POST", "/v1/names", { name: "community-garden", target: `http://localhost:${site.address().port}/members/` }, joined.pass);
    assert.equal(reg.status, 201, JSON.stringify(reg));
    await go("pol://community-garden/");
    await waitFor(async () => (await tabEval("document.getElementById('h') && document.getElementById('h').textContent")) === "Welcome to the community garden", "the member site");
    assert.ok(lastVisitHeader, "the site got x-polnet-visit");
    const claims = JSON.parse(Buffer.from(lastVisitHeader.split(".")[1], "base64url").toString());
    assert.equal(claims.typ, "visit");
    assert.equal(claims.aud, "pol://community-garden");
    assert.notEqual(claims.sub, joined.member.id, "the site never sees the member id");
    assert.equal((await state()).active.member, true);
    // A relative link stays on pol://.
    await tabEval("document.getElementById('next').click()");
    await waitFor(async () => (await tabUrl()) === "pol://community-garden/events", "pol:// relative link");
  });

  await check("an organisation's funded task appears in Tasks, a member claims it, and approval pays the wallet", async () => {
    await api("POST", `/v1/admin/posters/${org.member.id}`, {}, "dev-admin");
    const t = await api("POST", "/v1/org/tasks", { title: "Map step-free entrances", description: "Photograph and note which shops on Briggate have a step-free entrance, for a disability access map.", category: "accessibility", reward_pence: 600, slots: 3 }, org.pass);
    assert.equal(t.status, 201, JSON.stringify(t));
    await api("POST", `/v1/admin/tasks/${t.task.id}/fund`, {}, "dev-admin");
    await go("polnet://tasks/");
    await waitFor(async () => /Map step-free entrances/.test(await tabEval("document.body.innerText")), "the task in the list");
    await tabEval("[...document.querySelectorAll('button')].find((b) => b.textContent === 'Claim this task').click()");
    await waitFor(async () => /You have 72 hours to send your evidence/.test(await tabEval("document.body.innerText")), "claimed message");
    const claims = await api("GET", "/v1/claims", undefined, joined.pass);
    const claim = claims.claims[0];
    assert.equal(claim.status, "claimed");
    await api("POST", `/v1/claims/${claim.id}/submit`, { evidence_text: "14 shops checked, 9 step-free" }, joined.pass);
    const ok = await api("POST", `/v1/org/claims/${claim.id}/approve`, {}, org.pass);
    assert.equal(ok.claim.status, "approved");
    await go("polnet://wallet/");
    await waitFor(async () => /£6\.00/.test(await tabEval("document.body.innerText")), "£6.00 in the wallet");
  });

  await check("the browser's own pages cannot reach admin routes", async () => {
    await go("polnet://wallet/");
    await waitFor(async () => (await tabEval("typeof window.polnet")) === "object", "bridge on polnet:// pages");
    const r = await tabEval("window.polnet.api('POST', '/v1/admin/posters/x', {})");
    assert.equal(r.error, "not_allowed");
  });

  await check("a page that uses scam tricks is replaced by a warning that explains them", async () => {
    await go(`${SITE}/support`);
    await waitFor(async () => (await tabUrl()).startsWith("polnet://warning"), "the warning page");
    assert.match(await tabUrl(), /kind=scam-page/);
    await waitFor(async () => /phone a support line/.test(await tabEval("document.body.innerText")), "the explanation");
    assert.doesNotMatch(await tabEval("document.body.innerText"), /\bnull\b/);
  });

  await check("a site learns a real person is here, with consent, under an id only it sees", async () => {
    await go(`${SITE}/verify`);
    await waitFor(async () => (await tabEval("document.getElementById('prove') ? 1 : 0")) === 1, "the verify page");
    await tabEval("document.getElementById('prove').click()");
    await waitFor(async () => /asks if you are a real person/.test(await tabEval("document.body.innerText")), "the consent page");
    assert.match(await tabEval("document.body.innerText"), /will not get/);
    await tabEval("[...document.querySelectorAll('button')].find((b) => b.textContent.startsWith('Yes, tell')).click()");
    await waitFor(async () => (await tabUrl()).startsWith(`${SITE}/verified#pol_human=`), "back on the site with a pass");
    const token = new URLSearchParams(new URL(await tabUrl()).hash.slice(1)).get("pol_human");
    const claims = await verifyHumanPass(token, { origin: SITE, nonce: NONCE, issuer: "http://localhost:8787", jwksUrl: `${API}/.well-known/jwks.json` });
    assert.ok(claims, "the site verifies the pass with the published keys");
    assert.equal(claims.typ, "human");
    assert.notEqual(claims.sub, joined.member.id);
    // A page cannot ask on behalf of another site.
    await go(`${SITE}/verify-other`);
    await waitFor(async () => (await tabEval("document.getElementById('prove') ? 1 : 0")) === 1, "the other verify page");
    await tabEval("document.getElementById('prove').click()");
    await waitFor(async () => /did not come from shop.example/.test(await tabEval("document.body.innerText")), "the refusal");
  });

  await check("protected mode: remote-control and new-site pauses warn, and a helper hears only the host and kind", async () => {
    const helper = await api("POST", "/v1/join", { pol_token: "dev-e2e-helper", handle: "e2e_helper" });
    const inv = await api("POST", "/v1/helpers/invite", {}, joined.pass);
    assert.equal(inv.status, 201, JSON.stringify(inv));
    assert.equal((await api("POST", "/v1/helpers/accept", { code: inv.code }, helper.pass)).helping, "e2e_member");
    await main(() => global.__polnet.settings().set({ protectedMode: true }));
    await go("https://anydesk.com/");
    await waitFor(async () => /kind=remote-access/.test(await tabUrl()), "the remote-access warning");
    await waitFor(async () => /Is someone asking you to install this/.test(await tabEval("document.body.innerText")), "the warning text");
    assert.equal(await tabEval("[...document.querySelectorAll('button')].find((b) => b.textContent.startsWith('I asked someone')).disabled"), true, "open anyway waits first");
    await go(`${SITE}/login`);
    await waitFor(async () => /kind=pause/.test(await tabUrl()), "the pause before a password on a new site");
    const seen = await waitFor(async () => {
      const r = await api("GET", "/v1/helpers/alerts", undefined, helper.pass);
      return r.alerts && r.alerts.length >= 2 ? r : null;
    }, "two alerts for the helper");
    assert.deepEqual(seen.alerts.map((a) => a.kind).sort(), ["pause", "remote-access"]);
    assert.ok(seen.alerts.some((a) => a.host === "anydesk.com"));
    assert.deepEqual(Object.keys(seen.alerts[0]).sort(), ["at", "handle", "host", "kind"]);
    await main(() => global.__polnet.settings().set({ protectedMode: false }));
  });

  await check("a private window keeps no history", async () => {
    const before = await main(() => global.__polnet.settings().history().length);
    await main((_e, u) => global.__polnet.createWindow({ isPrivate: true, url: u }), `${SITE}/private-page`);
    await waitFor(async () => (await main(() => [...global.__polnet.windows].length)) === 2, "a second window");
    await sleep(1500);
    const after = await main(() => global.__polnet.settings().history());
    assert.equal(after.length, before);
    assert.ok(!after.some((h) => h.url.includes("private-page")));
  });

  await check("the Square: a member posts from the page, another member's video shows under HeliusTV, and a vote counts once", async () => {
    const video = await api("POST", "/v1/square", { topic: "tv", title: "How we cleaned the beck", link: "https://video.example/watch/beck" }, org.pass);
    assert.equal(video.status, 201, JSON.stringify(video));
    await go("polnet://square/");
    await waitFor(async () => /How we cleaned the beck/.test(await tabEval("document.body.innerText")), "the video post in the list");
    await tabEval(`(() => {
      document.querySelector("details.card").open = true;
      const f = document.querySelector("details.card");
      f.querySelector("select").value = "projects";
      f.querySelector("input").value = "A map of step-free shops";
      f.querySelector("textarea").value = "We are mapping which shops have a step-free entrance. Who wants to help?";
      [...f.querySelectorAll("button")].find((b) => b.textContent === "Post").click();
    })()`);
    await waitFor(async () => /A map of step-free shops/.test(await tabEval("document.getElementById('app').lastElementChild.innerText")), "the new post in the list");
    const listed = await api("GET", "/v1/square?topic=projects", undefined, org.pass);
    assert.deepEqual(listed.posts.map((x) => [x.title, x.author]), [["A map of step-free shops", "e2e_member"]]);
    // Vote for the video twice from the page: on, then off again.
    await go("polnet://square/?topic=tv");
    await waitFor(async () => (await tabEval("document.querySelector('h1').textContent")) === "HeliusTV" && /Watch/.test(await tabEval("document.body.innerText")), "the HeliusTV view");
    assert.doesNotMatch(await tabEval("document.body.innerText"), /step-free shops/, "only videos under HeliusTV");
    await tabEval("document.querySelector('button[aria-pressed]').click()");
    await waitFor(async () => (await api("GET", `/v1/square/${video.post.id}`, undefined, org.pass)).post.votes === 1, "one vote");
    await tabEval("document.querySelector('button[aria-pressed]').click()");
    await waitFor(async () => (await api("GET", `/v1/square/${video.post.id}`, undefined, org.pass)).post.votes === 0, "the vote taken back");
  });

  await check("the services page lists free before paid and never prices what is not built", async () => {
    await go("polnet://services/");
    await waitFor(async () => /POL Net browser/.test(await tabEval("document.body.innerText")), "the catalogue");
    const text = await tabEval("document.body.innerText");
    assert.match(text, /Travel and data eSIMs[\s\S]*Not on sale yet/);
    assert.match(text, /AI-Built App Security Check[\s\S]*US\$595/);
    const kinds = await tabEval("[...document.querySelectorAll('.grid')].map((g) => [...g.querySelectorAll('.card .row span:last-child')].map((x) => x.textContent))");
    for (const group of kinds) assert.deepEqual(group, [...group].sort((x, y) => (x === y ? 0 : x === "Free" ? -1 : 1)), "free first in every group");
  });

  await check("the toolbar renders with the member badge", async () => {
    const win = await app.firstWindow();
    await waitFor(async () => (await win.textContent("#member")) === "@e2e_member", "toolbar member badge");
  });
} finally {
  await app.close().catch(() => undefined);
  deno.kill();
  site.close();
}

const failed = results.filter((r) => r[0] === "FAIL");
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);
