"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("node:os");
const fs = require("node:fs");
const path = require("node:path");
const { toUrl } = require("../../src/main/urlbar");
const { PolNet, allowedApi, parsePolUrl, humanRequest } = require("../../src/main/polnet");
const { Olo, questionWithPage, ndjson } = require("../../src/main/olo");
const { Settings } = require("../../src/main/settings");
const { hostHash } = require("../../src/main/safety");

test("the address bar: addresses, pol:// names and private searches", () => {
  assert.equal(toUrl("example.org"), "https://example.org");
  assert.equal(toUrl("example.org/path?q=1"), "https://example.org/path?q=1");
  assert.equal(toUrl("https://x.example"), "https://x.example");
  assert.equal(toUrl("localhost:3000"), "http://localhost:3000");
  assert.equal(toUrl("pol://community-garden"), "pol://community-garden");
  assert.equal(toUrl("weather in leeds"), "https://duckduckgo.com/?q=weather%20in%20leeds");
  assert.equal(toUrl("weather", "brave"), "https://search.brave.com/search?q=weather");
  assert.equal(toUrl("javascript:alert(1)"), null);
  assert.equal(toUrl("file:///etc/passwd"), null);
  assert.equal(toUrl(""), null);
});

test("the browser's own pages may call only the listed API routes", () => {
  assert.ok(allowedApi("GET", "/v1/tasks"));
  assert.ok(allowedApi("GET", "/v1/tasks?category=health"));
  assert.ok(allowedApi("POST", "/v1/tasks/00000000-0000-4000-8000-000000000001/claim"));
  assert.ok(allowedApi("POST", "/v1/payouts"));
  assert.ok(!allowedApi("POST", "/v1/admin/posters/x"), "never admin routes");
  assert.ok(!allowedApi("GET", "/v1/names/community-garden"), "names resolve through pol:// only");
  assert.ok(!allowedApi("DELETE", "/v1/tasks"));
});

test("the Square and the services catalogue are reachable from the browser's pages, moderation is not", () => {
  const id = "00000000-0000-4000-8000-000000000001";
  assert.ok(allowedApi("GET", "/v1/services"));
  assert.ok(allowedApi("GET", "/v1/square"));
  assert.ok(allowedApi("GET", "/v1/square?topic=tv&sort=top"));
  assert.ok(allowedApi("GET", `/v1/square/${id}`));
  assert.ok(allowedApi("POST", "/v1/square"));
  assert.ok(allowedApi("POST", `/v1/square/${id}/vote`));
  assert.ok(allowedApi("POST", `/v1/square/${id}/comments`));
  assert.ok(allowedApi("DELETE", `/v1/square/${id}`));
  assert.ok(allowedApi("DELETE", `/v1/square/comments/${id}`));
  assert.ok(!allowedApi("POST", `/v1/admin/posts/${id}/remove`), "never admin routes");
  assert.ok(!allowedApi("POST", `/v1/square/${id}/anything`));
  assert.ok(!allowedApi("GET", "/v1/square/../admin"));
  assert.ok(allowedApi("GET", "/v1/checks/next"));
  assert.ok(allowedApi("GET", "/v1/checks/stats"));
  assert.ok(allowedApi("POST", `/v1/checks/${id}/label`));
  assert.ok(!allowedApi("POST", "/v1/admin/checks"));
  assert.ok(!allowedApi("GET", "/v1/admin/checks/export"));
  assert.ok(!allowedApi("GET", `/v1/checks/${id}`));
});

test("pol:// addresses", () => {
  assert.deepEqual(parsePolUrl("pol://community-garden"), { name: "community-garden", path: "/" });
  assert.deepEqual(parsePolUrl("pol://Garden/events?x=1#top"), { name: "garden", path: "/events?x=1" });
  assert.equal(parsePolUrl("pol://ab"), null);
  assert.equal(parsePolUrl("https://garden"), null);
});

test("the POL Net client caches names and sends only a hash prefix for safety checks", async () => {
  const calls = [];
  const flaggedHash = hostHash("bad.example");
  const f = async (url, init) => {
    calls.push({ url, auth: init.headers.authorization });
    if (url.includes("/v1/names/garden")) return Response.json({ name: "garden", target: "https://g.example/" });
    if (url.includes("/v1/safety?prefix=")) return Response.json({ flagged: url.endsWith(flaggedHash.slice(0, 8)) ? [flaggedHash] : [] });
    return Response.json({ error: "not_found" }, { status: 404 });
  };
  const c = new PolNet({ server: () => "https://s.example", pass: () => "PASS", fetch: f });
  assert.equal((await c.resolve("garden")).target, "https://g.example/");
  await c.resolve("garden");
  assert.equal(calls.filter((x) => x.url.includes("/names/garden")).length, 1, "cached");
  assert.equal(calls[0].auth, "Bearer PASS");
  assert.equal(await c.flagged("bad.example", hostHash), true);
  assert.equal(await c.flagged("good.example", hostHash), false);
  for (const x of calls.filter((y) => y.url.includes("safety"))) {
    assert.ok(!x.url.includes("bad.example") && !x.url.includes("good.example"), "the host name never leaves the computer");
    assert.match(x.url, /prefix=[0-9a-f]{8}$/);
  }
  const down = new PolNet({ server: () => "https://s.example", pass: () => null, fetch: async () => { throw new Error("offline"); } });
  assert.equal((await down.call("GET", "/v1/me")).error, "unreachable");
});

test("Olo: a session is made once, questions are private, the page is attached only when given, and the stream is parsed", async () => {
  let token = null;
  const sent = [];
  const stream = (lines) => new Response(new ReadableStream({ start(c) { for (const l of lines) c.enqueue(new TextEncoder().encode(l)); c.close(); } }), { headers: { "content-type": "application/x-ndjson" } });
  const f = async (url, init) => {
    if (url.endsWith("/api/trpc/auth.createSession")) return Response.json({ result: { data: { json: { token: "OLO", user: {} } } } });
    sent.push({ url, body: JSON.parse(init.body), auth: init.headers.authorization });
    return stream(['{"type":"start","conversationId":0}\n{"type":"del', 'ta","text":"Hello "}\n', '{"type":"delta","text":"world."}\n{"type":"verification","verification":{"claims":[1],"supported":1}}\n']);
  };
  const olo = new Olo({ base: () => "https://olo.example", token: () => token, setToken: (t) => { token = t; }, fetch: f });
  const events = [];
  const full = await olo.ask({ question: "Summarise", page: { title: "T", url: "https://p.example", text: "Body text" } }, (e) => events.push(e));
  assert.equal(full, "Hello world.");
  assert.equal(token, "OLO");
  assert.equal(sent[0].auth, "Bearer OLO");
  assert.equal(sent[0].body.private, true);
  assert.match(sent[0].body.content, /--- Attached: the web page I am reading ---[\s\S]*Body text/);
  assert.ok(events.some((e) => e.type === "verification"));
  assert.equal(questionWithPage("Q", null), "Q");
  assert.equal(questionWithPage("Q", { text: "x".repeat(20000) }).length < 12200, true);
  assert.deepEqual(ndjson('{"a":1}\n{"b"'), { events: [{ a: 1 }], rest: '{"b"' });
});

test("settings stay on this computer; secrets are encrypted when the keychain allows", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "polnet-settings-"));
  const fakeSafe = { isEncryptionAvailable: () => true, encryptString: (s) => Buffer.from(`enc:${s}`), decryptString: (b) => b.toString().slice(4) };
  const st = new Settings(dir, fakeSafe);
  assert.equal(st.get().search, "duckduckgo");
  st.setPass("SECRET-PASS", { handle: "river_fox" });
  const raw = fs.readFileSync(path.join(dir, "settings.json"), "utf8");
  assert.ok(!raw.includes("SECRET-PASS"), "the pass is never written in clear");
  assert.equal(new Settings(dir, fakeSafe).pass(), "SECRET-PASS");
  assert.equal(st.get().pass, undefined, "get() never exposes the pass");
  st.set({ server: "https://my.server/", evil: true });
  assert.equal(st.get().server, "https://my.server");
  assert.equal(st.get().evil, undefined);
  st.setSiteShields("news.example", false);
  assert.equal(st.siteShieldsOn("news.example"), false);
  assert.equal(st.siteShieldsOn("other.example"), true);
  st.addHistory("https://a.example/", "A");
  st.addHistory("https://a.example/", "A again");
  st.addHistory("polnet://settings/", "Settings");
  assert.equal(st.history().length, 1);
  st.set({ history: false });
  st.addHistory("https://b.example/", "B");
  assert.equal(st.history().length, 1);
  st.clearHistory();
  assert.equal(st.history().length, 0);
});

test("family help routes are allowed for the browser's pages, alerts and human passes are not", () => {
  assert.ok(allowedApi("GET", "/v1/helpers"));
  assert.ok(allowedApi("GET", "/v1/helpers/alerts"));
  assert.ok(allowedApi("POST", "/v1/helpers/invite"));
  assert.ok(allowedApi("POST", "/v1/helpers/accept"));
  assert.ok(allowedApi("DELETE", "/v1/helpers/00000000-0000-4000-8000-000000000001"));
  assert.ok(!allowedApi("POST", "/v1/helpers/alerts"), "only the main process sends alerts");
  assert.ok(!allowedApi("POST", "/v1/human"), "only the consent page, through the main process, asks for a human pass");
});

test("a real-person request goes only back to the site that asked, from that site", () => {
  const q = { origin: "https://shop.example", return: "https://shop.example/verified?x=1#old", nonce: "abcdefgh12" };
  const ok = humanRequest(q, "https://shop.example/checkout");
  assert.deepEqual(ok, { origin: "https://shop.example", returnTo: "https://shop.example/verified?x=1", nonce: "abcdefgh12", host: "shop.example" });
  assert.match(humanRequest(q, "https://evil.example/").error, /did not come from shop.example/);
  assert.match(humanRequest(q, null).error, /did not come from/);
  assert.match(humanRequest({ ...q, return: "https://evil.example/cb" }, "https://shop.example/").error, /different site/);
  assert.match(humanRequest({ ...q, origin: "http://shop.example", return: "http://shop.example/cb" }, "http://shop.example/").error, /secure/);
  assert.match(humanRequest({ ...q, origin: "https://shop.example/" }, "https://shop.example/").error, /secure/);
  assert.ok(humanRequest({ ...q, nonce: "x" }, "https://shop.example/").error);
  assert.ok(humanRequest({}, "https://shop.example/").error);
});

test("protected mode remembers first visits only while it is on, and forgets them when switched off", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "polnet-known-"));
  const s = new Settings(dir);
  s.noteHost("a.example");
  assert.equal(s.knownSince("a.example"), null, "nothing kept while protected mode is off");
  s.set({ protectedMode: true });
  s.noteHost("a.example");
  assert.ok(s.knownSince("a.example"));
  assert.ok(!("knownHosts" in s.get()), "pages never receive the list");
  s.clearKnownHosts();
  assert.equal(s.knownSince("a.example"), null);
});
