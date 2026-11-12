// deno-lint-ignore-file no-explicit-any
// deno test -A tests/   (POLNET_TEST_PG=postgres://... also runs the whole suite against real Postgres)
import { createApi, validHost, validName, validOrigin, validTarget } from "../supabase/functions/_shared/api.ts";
import { loadSigner, newSigningJwk, verify } from "../supabase/functions/_shared/jwt.ts";
import { MemoryStore, type Store } from "../supabase/functions/_shared/store.ts";

function assert(cond: unknown, msg = "assertion failed"): asserts cond {
  if (!cond) throw new Error(msg);
}
function eq<T>(a: T, b: T, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const ISS = "https://polnet.test";
const enc = new TextEncoder();

type Stripe = { calls: Array<{ path: string; body: string }>; failTransfer: boolean; payoutsEnabled: boolean };

async function harness(store: Store, opts: { stripe?: boolean; nowMs?: number; square?: boolean; esim?: string } = {}) {
  const signer = await loadSigner(await newSigningJwk());
  let clock = opts.nowMs ?? Date.parse("2026-11-08T12:00:00Z");
  const stripe: Stripe = { calls: [], failTransfer: false, payoutsEnabled: true };
  const fake: typeof fetch = async (input, init) => {
    const url = String(input);
    const body = String(init?.body ?? "");
    if (url.endsWith("/v1/siteverify")) {
      const b = JSON.parse(body);
      if (b.secret !== "sk_pol") return Response.json({ success: false, "error-codes": ["invalid-input-secret"] });
      if (b.expected_action !== "polnet_join") return Response.json({ success: false, "error-codes": ["action-mismatch"] });
      const [kind, who] = String(b.response).split(":");
      if (kind === "good") return Response.json({ success: true, human: true, subject: `sub_${who}`, uniqueness_level: "history", "error-codes": [] });
      if (kind === "weak") return Response.json({ success: true, human: true, subject: `sub_${who}`, uniqueness_level: "none", "error-codes": [] });
      return Response.json({ success: false, "error-codes": ["invalid-input-response"] });
    }
    if (url.startsWith("https://api.stripe.com/v1/")) {
      const path = url.slice("https://api.stripe.com/v1/".length);
      stripe.calls.push({ path, body });
      if (path === "accounts") return Response.json({ id: "acct_123" });
      if (path === "account_links") return Response.json({ url: "https://connect.stripe.test/onboard" });
      if (path === "accounts/acct_123") return Response.json({ id: "acct_123", payouts_enabled: stripe.payoutsEnabled });
      if (path === "transfers") return stripe.failTransfer ? Response.json({ error: { message: "insufficient platform funds" } }, { status: 400 }) : Response.json({ id: "tr_1" });
      if (path === "checkout/sessions") return Response.json({ url: "https://checkout.stripe.test/s" });
    }
    return new Response("not found", { status: 404 });
  };
  let n = 0;
  const handle = createApi({
    store, signer, fetch: fake, now: () => clock, id: () => `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`,
    config: {
      issuer: ISS, publicUrl: ISS, polApi: "https://pol.test", polSitekey: "pk_pol", polSecret: "sk_pol", adminSecret: "admin-secret",
      feeBps: 1000, minPayoutPence: 1000, minUniqueness: "device", squareOpen: opts.square, esimStoreUrl: opts.esim,
      stripeSecret: opts.stripe ? "sk_test_x" : undefined, stripeWebhookSecret: opts.stripe ? "whsec_x" : undefined,
    },
  });
  const call = async (method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}) => {
    const r = await handle(new Request(`${ISS}/functions/v1/polnet-api${path}`, {
      method, body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    }));
    const text = await r.text();
    let j: Record<string, unknown> = {};
    try { j = JSON.parse(text); } catch { j = { text }; }
    return { status: r.status, j: j as Record<string, any> };
  };
  const join = async (who: string, handleName: string) => {
    const r = await call("POST", "/v1/join", { pol_token: `good:${who}:padding`, handle: handleName });
    assert(r.status === 200, `join ${who}: ${JSON.stringify(r.j)}`);
    return { pass: r.j.pass as string, id: r.j.member.id as string };
  };
  return { call, join, signer, stripe, tick: (ms: number) => { clock += ms; }, now: () => clock };
}

async function suite(name: string, makeStore: () => Promise<Store>) {
  Deno.test(`${name}: health, keys and config are public`, async () => {
    const h = await harness(await makeStore());
    eq((await h.call("GET", "/v1/health")).j.ok, true);
    const k = await h.call("GET", "/.well-known/jwks.json");
    eq(k.j.keys[0].kty, "EC");
    assert(!("d" in k.j.keys[0]), "private key must never be published");
    eq((await h.call("GET", "/v1/config")).j.pol_sitekey, "pk_pol");
    const page = await h.call("GET", "/join");
    assert(String(page.j.text).includes("Join POL Net") && String(page.j.text).includes("pk_pol"));
  });

  Deno.test(`${name}: one real person, one account`, async () => {
    const h = await harness(await makeStore());
    eq((await h.call("POST", "/v1/join", { pol_token: "bad:x:padding", handle: "river_fox" })).status, 403);
    eq((await h.call("POST", "/v1/join", { pol_token: "weak:a:padding", handle: "river_fox" })).j.error, "uniqueness_too_low");
    eq((await h.call("POST", "/v1/join", { pol_token: "good:a:padding", handle: "No Spaces!" })).j.error, "handle_invalid");
    eq((await h.call("POST", "/v1/join", { pol_token: "good:a:padding", handle: "admin" })).j.error, "handle_invalid");
    const a = await h.join("a", "river_fox");
    const claims = await verify(a.pass, [h.signer.publicJwk], ISS, h.now());
    eq(claims?.typ, "member");
    eq(claims?.handle, "river_fox");
    // The same person joining again gets the same account, whatever handle they type.
    const again = await h.call("POST", "/v1/join", { pol_token: "good:a:padding", handle: "someone_else" });
    eq(again.j.member.id, a.id);
    eq(again.j.member.handle, "river_fox");
    eq((await h.call("POST", "/v1/join", { pol_token: "good:b:padding", handle: "RIVER_FOX" })).j.error, "handle_taken");
    eq((await h.call("GET", "/v1/me")).status, 401);
    eq((await h.call("GET", "/v1/me", undefined, a.pass)).j.member.handle, "river_fox");
    eq((await h.call("GET", "/v1/me", undefined, a.pass.slice(0, -4) + "AAAA")).status, 401);
    h.tick(31 * 86400_000);
    eq((await h.call("GET", "/v1/me", undefined, a.pass)).j.error, "pass_invalid");
  });

  Deno.test(`${name}: pol:// names resolve only for members, and reports take them down`, async () => {
    const h = await harness(await makeStore());
    const a = await h.join("a", "alice");
    eq((await h.call("POST", "/v1/names", { name: "Bad Name", target: "https://x.example" }, a.pass)).j.error, "name_invalid");
    eq((await h.call("POST", "/v1/names", { name: "paypal", target: "https://x.example" }, a.pass)).j.error, "name_invalid");
    eq((await h.call("POST", "/v1/names", { name: "garden", target: "http://x.example" }, a.pass)).j.error, "target_invalid");
    eq((await h.call("POST", "/v1/names", { name: "garden", target: "https://169.254.169.254/latest" }, a.pass)).j.error, "target_invalid");
    eq((await h.call("POST", "/v1/names", { name: "community-garden", target: "https://garden.example/", description: "Leeds allotments" }, a.pass)).status, 201);
    eq((await h.call("POST", "/v1/names", { name: "community-garden", target: "https://other.example/" }, a.pass)).j.error, "name_taken");
    eq((await h.call("GET", "/v1/names/community-garden")).status, 401);
    const r = await h.call("GET", "/v1/names/community-garden", undefined, a.pass);
    eq(r.j.target, "https://garden.example/");
    eq(r.j.owner, "alice");
    eq((await h.call("GET", "/v1/names/nothing-here", undefined, a.pass)).status, 404);
    const reporters = [await h.join("b", "bob"), await h.join("c", "carol"), await h.join("d", "dave")];
    for (const [i, m] of reporters.entries()) {
      const rep = await h.call("POST", "/v1/reports", { kind: "name", target: "community-garden", reason: "phishing page" }, m.pass);
      eq(rep.j.reports, i + 1);
      // The same member reporting twice counts once.
      eq((await h.call("POST", "/v1/reports", { kind: "name", target: "community-garden", reason: "again" }, m.pass)).j.reports, i + 1);
    }
    eq((await h.call("GET", "/v1/names/community-garden", undefined, a.pass)).status, 451);
    eq((await h.call("POST", "/v1/admin/names/community-garden/restore", {}, "wrong")).status, 401);
    eq((await h.call("POST", "/v1/admin/names/community-garden/restore", {}, "admin-secret")).j.name.suspended, false);
    eq((await h.call("GET", "/v1/names/community-garden", undefined, a.pass)).status, 200);
    // A visit pass is per site, pairwise, short, and refused by the API itself.
    const v1 = await h.call("POST", "/v1/names/community-garden/visit", {}, a.pass);
    const visit = await verify(v1.j.visit, [h.signer.publicJwk], ISS, h.now());
    eq(visit?.typ, "visit");
    eq(visit?.aud, "pol://community-garden");
    assert(visit?.sub !== a.id, "the site never sees the member id");
    await h.call("POST", "/v1/names", { name: "other-site", target: "https://other.example/" }, a.pass);
    const v2 = await verify((await h.call("POST", "/v1/names/other-site/visit", {}, a.pass)).j.visit, [h.signer.publicJwk], ISS, h.now());
    assert(v2?.sub !== visit?.sub, "two sites cannot link the same member");
    eq((await h.call("GET", "/v1/me", undefined, v1.j.visit)).status, 401, "a leaked visit pass is useless against the API");
    eq((await h.call("DELETE", "/v1/names/community-garden", undefined, reporters[0].pass)).j.deleted, false);
    eq((await h.call("DELETE", "/v1/names/community-garden", undefined, a.pass)).j.deleted, true);
  });

  Deno.test(`${name}: an organisation posts a funded task, members do it and get paid into the ledger`, async () => {
    const h = await harness(await makeStore());
    const org = await h.join("org", "leeds_rivers_trust");
    const w1 = await h.join("w1", "worker_one");
    const w2 = await h.join("w2", "worker_two");
    const w3 = await h.join("w3", "worker_three");
    const task = { title: "Photograph litter hotspots", description: "Photograph and geotag litter hotspots along the River Aire between Kirkstall and the city centre.", category: "environment", reward_pence: 750, slots: 2 };
    eq((await h.call("POST", "/v1/org/tasks", task, org.pass)).j.error, "poster_only");
    eq((await h.call("POST", `/v1/admin/posters/${org.id}`, {}, "admin-secret")).j.member.role, "poster");
    eq((await h.call("POST", "/v1/org/tasks", { ...task, reward_pence: 10 }, org.pass)).j.error, "task_invalid");
    eq((await h.call("POST", "/v1/org/tasks", { ...task, category: "crypto" }, org.pass)).j.error, "task_invalid");
    const created = await h.call("POST", "/v1/org/tasks", task, org.pass);
    eq(created.status, 201);
    eq(created.j.to_fund_pence, 1650, "rewards 1,500 plus a 10% fee paid by the organisation");
    const id = created.j.task.id as string;
    eq((await h.call("GET", "/v1/tasks", undefined, w1.pass)).j.tasks.length, 0, "a draft is not listed");
    eq((await h.call("POST", `/v1/tasks/${id}/claim`, {}, w1.pass)).j.error, "task_not_open");
    eq((await h.call("POST", `/v1/org/tasks/${id}/fund`, {}, org.pass)).j.error, "payments_not_configured");
    eq((await h.call("POST", `/v1/admin/tasks/${id}/fund`, {}, "admin-secret")).j.task.status, "open");
    const list = await h.call("GET", "/v1/tasks?category=environment", undefined, w1.pass);
    eq(list.j.tasks.length, 1);
    eq(list.j.tasks[0].slots_left, 2);
    eq((await h.call("POST", `/v1/tasks/${id}/claim`, {}, org.pass)).j.error, "own_task");
    const c1 = await h.call("POST", `/v1/tasks/${id}/claim`, {}, w1.pass);
    eq(c1.status, 201);
    eq((await h.call("POST", `/v1/tasks/${id}/claim`, {}, w1.pass)).j.error, "already_claimed");
    const c2 = await h.call("POST", `/v1/tasks/${id}/claim`, {}, w2.pass);
    eq(c2.status, 201);
    eq((await h.call("POST", `/v1/tasks/${id}/claim`, {}, w3.pass)).j.error, "no_slots");
    eq((await h.call("GET", "/v1/tasks", undefined, w3.pass)).j.tasks.length, 0, "a full task leaves the list");
    // Claims nobody works on expire after 72 hours and free their slot.
    h.tick(73 * 3600_000);
    eq((await h.call("POST", `/v1/claims/${c1.j.claim.id}/submit`, { evidence_text: "" }, w1.pass)).j.error, "evidence_required");
    eq((await h.call("POST", `/v1/claims/${c1.j.claim.id}/submit`, { evidence_url: "http://insecure.example" }, w1.pass)).j.error, "evidence_url_invalid");
    eq((await h.call("POST", `/v1/claims/${c1.j.claim.id}/submit`, { evidence_text: "12 hotspots photographed", evidence_url: "https://photos.example/aire" }, w1.pass)).j.claim.status, "submitted");
    eq((await h.call("POST", `/v1/claims/${c1.j.claim.id}/submit`, { evidence_text: "mine now" }, w2.pass)).j.error, "claim_not_submittable");
    const c3 = await h.call("POST", `/v1/tasks/${id}/claim`, {}, w3.pass);
    eq(c3.status, 201, "w2's stale claim expired and freed a slot");
    const mine = await h.call("GET", "/v1/claims", undefined, w2.pass);
    eq(mine.j.claims[0].status, "rejected");
    eq(mine.j.claims[0].note, "expired");
    // Review.
    eq((await h.call("POST", `/v1/org/claims/${c1.j.claim.id}/approve`, {}, w1.pass)).j.error, "poster_only");
    const review = await h.call("GET", `/v1/org/tasks/${id}/claims`, undefined, org.pass);
    assert(!JSON.stringify(review.j).includes("worker_one"), "posters never see member handles");
    eq((await h.call("POST", `/v1/org/claims/${c1.j.claim.id}/approve`, { note: "Thank you" }, org.pass)).j.claim.status, "approved");
    eq((await h.call("POST", `/v1/org/claims/${c1.j.claim.id}/approve`, {}, org.pass)).j.error, "claim_not_reviewable", "no double reward");
    eq((await h.call("POST", `/v1/claims/${c3.j.claim.id}/submit`, { evidence_text: "done" }, w3.pass)).status, 200);
    eq((await h.call("POST", `/v1/org/claims/${c3.j.claim.id}/reject`, { note: "No photos attached" }, org.pass)).j.claim.status, "rejected");
    const wallet = await h.call("GET", "/v1/wallet", undefined, w1.pass);
    eq(wallet.j.balances.GBP, 750);
    eq(wallet.j.entries[0].kind, "task_reward");
    eq((await h.call("GET", "/v1/wallet", undefined, w3.pass)).j.balances.GBP, 0);
    eq((await h.call("POST", "/v1/payouts", {}, w1.pass)).j.error, "payments_not_configured");
  });

  Deno.test(`${name}: payouts through Stripe Connect, reversed if the transfer fails`, async () => {
    const h = await harness(await makeStore(), { stripe: true });
    const org = await h.join("org", "aid_org");
    const w = await h.join("w", "helper");
    await h.call("POST", `/v1/admin/posters/${org.id}`, {}, "admin-secret");
    const t = await h.call("POST", "/v1/org/tasks", { title: "Translate a flyer", description: "Translate a one-page food bank flyer from English into Polish, plain words.", category: "translation", reward_pence: 1200, slots: 1 }, org.pass);
    const id = t.j.task.id;
    eq((await h.call("POST", `/v1/org/tasks/${id}/fund`, {}, org.pass)).j.checkout_url, "https://checkout.stripe.test/s");
    // The webhook opens the task only with a valid signature and enough money.
    const event = JSON.stringify({ type: "checkout.session.completed", data: { object: { payment_status: "paid", amount_total: 1320, metadata: { polnet_task: id } } } });
    eq((await h.call("POST", "/v1/stripe/webhook", event, undefined, { "stripe-signature": "t=1,v1=bad" })).j.error, "bad_signature");
    const ts = Math.floor(h.now() / 1000);
    const key = await crypto.subtle.importKey("raw", enc.encode("whsec_x"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = [...new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${ts}.${event}`)))].map((b) => b.toString(16).padStart(2, "0")).join("");
    eq((await h.call("POST", "/v1/stripe/webhook", event, undefined, { "stripe-signature": `t=${ts},v1=${mac}` })).j.received, true);
    eq((await h.call("GET", `/v1/tasks/${id}`, undefined, w.pass)).j.task.status, "open");
    const c = await h.call("POST", `/v1/tasks/${id}/claim`, {}, w.pass);
    await h.call("POST", `/v1/claims/${c.j.claim.id}/submit`, { evidence_url: "https://docs.example/flyer-pl" }, w.pass);
    await h.call("POST", `/v1/org/claims/${c.j.claim.id}/approve`, {}, org.pass);
    eq((await h.call("POST", "/v1/payouts", {}, w.pass)).j.error, "payout_account_needed");
    eq((await h.call("POST", "/v1/payouts/onboard", {}, w.pass)).j.onboarding_url, "https://connect.stripe.test/onboard");
    eq((await h.call("GET", "/v1/payouts/status", undefined, w.pass)).j.payouts_enabled, true);
    eq((await h.call("POST", "/v1/payouts", { amount_pence: 500 }, w.pass)).j.error, "below_minimum");
    eq((await h.call("POST", "/v1/payouts", { amount_pence: 5000 }, w.pass)).j.error, "insufficient_balance");
    h.stripe.failTransfer = true;
    eq((await h.call("POST", "/v1/payouts", {}, w.pass)).j.error, "stripe_error");
    eq((await h.call("GET", "/v1/wallet", undefined, w.pass)).j.balances.GBP, 1200, "a failed transfer is reversed");
    h.stripe.failTransfer = false;
    const paid = await h.call("POST", "/v1/payouts", {}, w.pass);
    eq(paid.status, 201);
    eq(paid.j.paid_pence, 1200);
    eq((await h.call("GET", "/v1/wallet", undefined, w.pass)).j.balances.GBP, 0);
    assert(h.stripe.calls.some((x) => x.path === "transfers" && x.body.includes("destination=acct_123")));
  });

  Deno.test(`${name}: sites reported by three members are on the safety list, looked up by hash prefix`, async () => {
    const h = await harness(await makeStore());
    const ms = [await h.join("s1", "safety_one"), await h.join("s2", "safety_two"), await h.join("s3", "safety_three")];
    const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode("paypa1-login.example")))].map((b) => b.toString(16).padStart(2, "0")).join("");
    eq((await h.call("GET", `/v1/safety?prefix=${hash.slice(0, 8)}`, undefined, ms[0].pass)).j.flagged, []);
    for (const m of ms) await h.call("POST", "/v1/reports", { kind: "site", target: "https://paypa1-login.example/verify?id=1", reason: "fake PayPal login" }, m.pass);
    eq((await h.call("GET", `/v1/safety?prefix=${hash.slice(0, 8)}`, undefined, ms[0].pass)).j.flagged, [hash]);
    eq((await h.call("GET", "/v1/safety?prefix=zz", undefined, ms[0].pass)).status, 400);
  });

  Deno.test(`${name}: ten members racing for two slots get exactly two`, async () => {
    const h = await harness(await makeStore());
    const org = await h.join("org", "race_org");
    await h.call("POST", `/v1/admin/posters/${org.id}`, {}, "admin-secret");
    const t = await h.call("POST", "/v1/org/tasks", { title: "Count bus shelters", description: "Count the bus shelters with working timetables on route 72 and note the stop codes.", category: "local-data", reward_pence: 300, slots: 2 }, org.pass);
    await h.call("POST", `/v1/admin/tasks/${t.j.task.id}/fund`, {}, "admin-secret");
    const racers = await Promise.all(Array.from({ length: 10 }, (_, i) => h.join(`r${i}`, `racer_${i}`)));
    const results = await Promise.all(racers.map((r) => h.call("POST", `/v1/tasks/${t.j.task.id}/claim`, {}, r.pass)));
    eq(results.filter((r) => r.status === 201).length, 2);
    eq(results.filter((r) => r.j.error === "no_slots").length, 8);
  });

  Deno.test(`${name}: reports close a task, and suspended members are locked out`, async () => {
    const h = await harness(await makeStore());
    const org = await h.join("o", "shady_org");
    await h.call("POST", `/v1/admin/posters/${org.id}`, {}, "admin-secret");
    const t = await h.call("POST", "/v1/org/tasks", { title: "Click these ads", description: "Click every advert on this page fifty times a day for a week.", category: "research", reward_pence: 100, slots: 50 }, org.pass);
    await h.call("POST", `/v1/admin/tasks/${t.j.task.id}/fund`, {}, "admin-secret");
    for (const who of ["r1", "r2", "r3"]) {
      const m = await h.join(who, `reporter_${who}`);
      const r = await h.call("POST", "/v1/reports", { kind: "task", target: t.j.task.id, reason: "ad fraud" }, m.pass);
      if (who === "r3") eq(r.j.action, "task_closed");
    }
    eq((await h.call("GET", `/v1/tasks/${t.j.task.id}`, undefined, org.pass)).j.task.status, "closed");
    await h.call("POST", `/v1/admin/members/${org.id}/suspend`, {}, "admin-secret");
    eq((await h.call("GET", "/v1/me", undefined, org.pass)).j.error, "member_suspended");
    eq((await h.call("POST", "/v1/join", { pol_token: "good:o:padding", handle: "x_y_z" })).j.error, "member_suspended", "a suspended person cannot rejoin under a new handle");
  });

  Deno.test(`${name}: family help links a helper by code, and alerts carry only the host and kind`, async () => {
    const h = await harness(await makeStore());
    const gran = await h.join("gran", "gran_may");
    const son = await h.join("son", "son_tom");
    const other = await h.join("other", "other_one");
    // No helper yet: an alert goes nowhere and nothing is stored.
    eq((await h.call("POST", "/v1/helpers/alerts", { host: "paypa1.com", kind: "lookalike" }, gran.pass)).j.sent, 0);
    const inv = await h.call("POST", "/v1/helpers/invite", {}, gran.pass);
    eq(inv.status, 201);
    assert(/^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/.test(inv.j.code), inv.j.code);
    eq((await h.call("POST", "/v1/helpers/accept", { code: inv.j.code }, gran.pass)).j.error, "own_code", "nobody can help themselves");
    const inv2 = await h.call("POST", "/v1/helpers/invite", {}, gran.pass);
    eq((await h.call("POST", "/v1/helpers/accept", { code: inv2.j.code.toLowerCase().replace("-", " ") }, son.pass)).j.helping, "gran_may", "codes forgive case and spacing");
    eq((await h.call("POST", "/v1/helpers/accept", { code: inv2.j.code }, other.pass)).j.error, "code_unknown", "a code works once");
    const list = await h.call("GET", "/v1/helpers", undefined, gran.pass);
    eq(list.j.helpers.map((x: any) => x.handle), ["son_tom"]);
    eq((await h.call("GET", "/v1/helpers", undefined, son.pass)).j.helping.map((x: any) => x.handle), ["gran_may"]);
    // Alerts: validated, and the helper sees host, kind and when; the other member sees nothing.
    eq((await h.call("POST", "/v1/helpers/alerts", { host: "not a host", kind: "lookalike" }, gran.pass)).status, 400);
    eq((await h.call("POST", "/v1/helpers/alerts", { host: "anydesk.com", kind: "keylogger" }, gran.pass)).status, 400);
    eq((await h.call("POST", "/v1/helpers/alerts", { host: "AnyDesk.com", kind: "remote-access", url: "https://anydesk.com/secret?x=1" }, gran.pass)).j.sent, 1);
    const seen = await h.call("GET", "/v1/helpers/alerts", undefined, son.pass);
    eq(seen.j.alerts.length, 1);
    eq(Object.keys(seen.j.alerts[0]).sort(), ["at", "handle", "host", "kind"]);
    eq(seen.j.alerts[0].host, "anydesk.com");
    eq((await h.call("GET", "/v1/helpers/alerts", undefined, other.pass)).j.alerts.length, 0);
    // Alerts older than 30 days are not shown.
    h.tick(20 * 86400_000);
    son.pass = (await h.call("GET", "/v1/me", undefined, son.pass)).j.pass;
    gran.pass = (await h.call("GET", "/v1/me", undefined, gran.pass)).j.pass;
    other.pass = (await h.call("GET", "/v1/me", undefined, other.pass)).j.pass;
    h.tick(11 * 86400_000);
    eq((await h.call("GET", "/v1/helpers/alerts", undefined, son.pass)).j.alerts.length, 0);
    // Either side ends the link; then alerts stop reaching the helper.
    eq((await h.call("DELETE", `/v1/helpers/${list.j.helpers[0].id}`, undefined, other.pass)).j.ended, false, "a stranger cannot end it");
    eq((await h.call("DELETE", `/v1/helpers/${list.j.helpers[0].id}`, undefined, son.pass)).j.ended, true);
    eq((await h.call("POST", "/v1/helpers/alerts", { host: "anydesk.com", kind: "remote-access" }, gran.pass)).j.sent, 0);
    // Invites expire after a day.
    const late = await h.call("POST", "/v1/helpers/invite", {}, gran.pass);
    h.tick(25 * 3600_000);
    eq((await h.call("POST", "/v1/helpers/accept", { code: late.j.code }, son.pass)).j.error, "code_unknown");
  });

  Deno.test(`${name}: at most three helpers`, async () => {
    const h = await harness(await makeStore());
    const p = await h.join("p", "protected_p");
    for (const who of ["a", "b", "c"]) {
      const inv = await h.call("POST", "/v1/helpers/invite", {}, p.pass);
      const helper = await h.join(who, `helper_${who}`);
      eq((await h.call("POST", "/v1/helpers/accept", { code: inv.j.code }, helper.pass)).status, 201);
    }
    eq((await h.call("POST", "/v1/helpers/invite", {}, p.pass)).j.error, "helper_limit");
  });

  Deno.test(`${name}: human passes are per site, unlinkable, short and bound to a nonce`, async () => {
    const h = await harness(await makeStore());
    const a = await h.join("ha", "human_a");
    eq((await h.call("POST", "/v1/human", { origin: "https://shop.example", nonce: "n0nce-123" })).status, 401, "members only");
    for (const bad of ["http://shop.example", "https://shop.example/", "https://shop.example/path", "https://localhost", "https://10.0.0.1", "javascript:alert(1)"]) {
      eq((await h.call("POST", "/v1/human", { origin: bad, nonce: "n0nce-123" }, a.pass)).j.error, "origin_invalid", bad);
    }
    eq((await h.call("POST", "/v1/human", { origin: "https://shop.example", nonce: "short" }, a.pass)).j.error, "nonce_invalid");
    const one = await h.call("POST", "/v1/human", { origin: "https://shop.example", nonce: "n0nce-123" }, a.pass);
    const two = await h.call("POST", "/v1/human", { origin: "https://forum.example", nonce: "n0nce-456" }, a.pass);
    const again = await h.call("POST", "/v1/human", { origin: "https://shop.example", nonce: "n0nce-789" }, a.pass);
    const c1 = await verify(one.j.human, [h.signer.publicJwk], ISS, h.now());
    const c2 = await verify(two.j.human, [h.signer.publicJwk], ISS, h.now());
    const c3 = await verify(again.j.human, [h.signer.publicJwk], ISS, h.now());
    assert(c1 && c2 && c3);
    eq([c1.typ, c1.aud, c1.nonce], ["human", "https://shop.example", "n0nce-123"]);
    eq(c1.sub, c3.sub, "stable for one site");
    assert(c1.sub !== c2.sub && c1.sub !== a.id, "different on every site and never the member id");
    eq(Number(c1.exp) - Number(c1.iat), 300);
    eq((await h.call("GET", "/v1/me", undefined, one.j.human)).status, 401, "a human pass is useless against the API");
    assert(!(await verify(one.j.human, [h.signer.publicJwk], ISS, h.now() + 301_000)), "expired after five minutes");
  });

  Deno.test(`${name}: the services catalogue is public and says what is free, paid and not built`, async () => {
    const h = await harness(await makeStore());
    const r = await h.call("GET", "/v1/services");
    eq(r.status, 200);
    const by = new Map<string, any>(r.j.services.map((x: any) => [x.key, x]));
    eq(by.get("polnet").kind, "free");
    eq(by.get("square").status, "soon", "the Square is not announced as live while it is closed");
    eq(by.get("task-posting").price.includes("10%"), true, "the fee shown is the fee charged");
    eq([by.get("esim").status, by.get("esim").url], ["planned", null]);
    for (const x of r.j.services) {
      assert(x.kind === "free" || x.kind === "paid");
      assert(x.group in r.j.groups, x.group);
      if (x.status === "planned") assert(!/[£$€]\s?\d/.test(x.price), `${x.key}: no price for something that is not built`);
      if (x.url !== null) assert(String(x.url).startsWith("https://"), x.key);
    }
    const open = await harness(await makeStore(), { square: true, esim: "https://store.example/helius" });
    const o = new Map<string, any>((await open.call("GET", "/v1/services")).j.services.map((x: any) => [x.key, x]));
    eq([o.get("square").status, o.get("heliustv").status, o.get("esim").status, o.get("esim").url], ["live", "live", "live", "https://store.example/helius"]);
    const bad = await harness(await makeStore(), { esim: "http://store.example" });
    eq(new Map<string, any>((await bad.call("GET", "/v1/services")).j.services.map((x: any) => [x.key, x])).get("esim").status, "planned", "only an https store address is shown");
  });

  Deno.test(`${name}: the Square is closed unless it is switched on`, async () => {
    const h = await harness(await makeStore());
    const a = await h.join("sq0", "closed_sq");
    eq((await h.call("GET", "/v1/square", undefined, a.pass)).j.error, "square_not_open");
    eq((await h.call("POST", "/v1/square", { topic: "ideas", title: "An idea worth sharing", body: "Twenty characters of text at least." }, a.pass)).status, 503);
    eq((await h.call("GET", "/v1/config")).j.square, false);
  });

  Deno.test(`${name}: the Square: members post, comment and vote once each; three reports take a post down`, async () => {
    const h = await harness(await makeStore(), { square: true });
    eq((await h.call("GET", "/v1/square")).status, 401, "members only");
    const [a, b, c, d] = [await h.join("sqa", "sq_alice"), await h.join("sqb", "sq_bob"), await h.join("sqc", "sq_cara"), await h.join("sqd", "sq_dev")];
    eq((await h.call("GET", "/v1/config")).j.topics.includes("tv"), true);

    eq((await h.call("POST", "/v1/square", { topic: "gossip", title: "A fine title", body: "Twenty characters of text at least." }, a.pass)).j.error, "post_invalid");
    eq((await h.call("POST", "/v1/square", { topic: "ideas", title: "Hey", body: "Twenty characters of text at least." }, a.pass)).j.error, "post_invalid");
    eq((await h.call("POST", "/v1/square", { topic: "ideas", title: "A fine title", body: "too short" }, a.pass)).j.error, "post_invalid");
    eq((await h.call("POST", "/v1/square", { topic: "ideas", title: "A fine title", body: "Twenty characters of text at least.", link: "http://plain.example" }, a.pass)).j.error, "link_invalid");
    eq((await h.call("POST", "/v1/square", { topic: "ideas", title: "A fine title", body: "Twenty characters of text at least.", link: "https://10.0.0.1/x" }, a.pass)).j.error, "link_invalid");
    eq((await h.call("POST", "/v1/square", { topic: "tv", title: "A film about a river" }, a.pass)).j.error, "link_required");

    const p1 = await h.call("POST", "/v1/square", { topic: "projects", title: "A map of step-free shops", body: "We are mapping which shops have a step-free entrance. Who wants to help?" }, a.pass);
    eq(p1.status, 201);
    eq([p1.j.post.author, p1.j.post.mine, p1.j.post.votes, p1.j.post.voted], ["sq_alice", true, 0, false]);
    h.tick(1000);
    const tv = await h.call("POST", "/v1/square", { topic: "tv", title: "How we cleaned the beck", link: "https://video.example/watch/beck" }, b.pass);
    eq([tv.status, tv.j.post.link, tv.j.post.body], [201, "https://video.example/watch/beck", ""]);
    assert(!("author_id" in tv.j.post) && !JSON.stringify(tv.j).includes(b.id), "member ids never leave the server");

    // One person, one vote: voting twice counts once, and a vote can be taken back.
    eq((await h.call("POST", `/v1/square/${p1.j.post.id}/vote`, {}, b.pass)).j.votes, 1);
    eq((await h.call("POST", `/v1/square/${p1.j.post.id}/vote`, { on: true }, b.pass)).j.votes, 1);
    eq((await h.call("POST", `/v1/square/${p1.j.post.id}/vote`, {}, c.pass)).j.votes, 2);
    eq((await h.call("POST", `/v1/square/${p1.j.post.id}/vote`, { on: false }, c.pass)).j, { votes: 1, voted: false });
    eq((await h.call("POST", "/v1/square/00000000-0000-4000-8000-999999999999/vote", {}, c.pass)).j.error, "post_not_found");
    eq((await h.call("POST", "/v1/square/not-an-id/vote", {}, c.pass)).j.error, "post_not_found");

    const newest = await h.call("GET", "/v1/square", undefined, b.pass);
    eq(newest.j.posts.map((x: any) => x.title), ["How we cleaned the beck", "A map of step-free shops"]);
    eq(newest.j.posts.map((x: any) => [x.voted, x.mine]), [[false, true], [true, false]]);
    eq((await h.call("GET", "/v1/square?sort=top", undefined, c.pass)).j.posts.map((x: any) => x.votes), [1, 0]);
    eq((await h.call("GET", "/v1/square?topic=tv", undefined, c.pass)).j.posts.length, 1);
    eq((await h.call("GET", "/v1/square?topic=nope", undefined, c.pass)).j.error, "topic_invalid");

    eq((await h.call("POST", `/v1/square/${p1.j.post.id}/comments`, { body: "" }, b.pass)).j.error, "comment_invalid");
    const c1 = await h.call("POST", `/v1/square/${p1.j.post.id}/comments`, { body: "I can do the top of Briggate on Saturday." }, b.pass);
    eq([c1.status, c1.j.comment.author, c1.j.comment.mine], [201, "sq_bob", true]);
    h.tick(1000);
    await h.call("POST", `/v1/square/${p1.j.post.id}/comments`, { body: "Count me in." }, c.pass);
    const one = await h.call("GET", `/v1/square/${p1.j.post.id}`, undefined, a.pass);
    eq([one.j.post.comments, one.j.comments.map((x: any) => x.author)], [2, ["sq_bob", "sq_cara"]]);
    eq((await h.call("DELETE", `/v1/square/comments/${c1.j.comment.id}`, undefined, c.pass)).j.deleted, false, "only the author deletes a comment");
    eq((await h.call("DELETE", `/v1/square/comments/${c1.j.comment.id}`, undefined, b.pass)).j.deleted, true);
    eq((await h.call("DELETE", `/v1/square/${p1.j.post.id}`, undefined, b.pass)).j.deleted, false, "only the author deletes a post");

    // Three different verified people take a post down; the same person reporting twice counts once.
    const report = (who: { pass: string }) => h.call("POST", "/v1/reports", { kind: "post", target: tv.j.post.id, reason: "This is an advert, not a video." }, who.pass);
    eq((await report(a)).j.action, null);
    eq((await report(a)).j.reports, 1);
    eq((await report(c)).j.action, null);
    eq((await report(d)).j.action, "post_removed");
    eq((await h.call("GET", `/v1/square/${tv.j.post.id}`, undefined, a.pass)).status, 451);
    eq((await h.call("POST", `/v1/square/${tv.j.post.id}/comments`, { body: "Still here?" }, a.pass)).status, 451);
    eq((await h.call("GET", "/v1/square", undefined, a.pass)).j.posts.map((x: any) => x.title), ["A map of step-free shops"]);
    eq((await h.call("POST", `/v1/admin/posts/${tv.j.post.id}/restore`, {}, a.pass)).status, 401, "a member pass is not the admin secret");
    eq((await h.call("POST", `/v1/admin/posts/${tv.j.post.id}/restore`, {}, "admin-secret")).j.removed, false);
    eq((await h.call("GET", "/v1/square", undefined, a.pass)).j.posts.length, 2);

    // The author deletes their own post; its comments and votes go with it.
    eq((await h.call("DELETE", `/v1/square/${p1.j.post.id}`, undefined, a.pass)).j.deleted, true);
    eq((await h.call("GET", `/v1/square/${p1.j.post.id}`, undefined, a.pass)).status, 404);

    // A suspended member cannot post, and a post rate limit holds.
    await h.call("POST", `/v1/admin/members/${d.id}/suspend`, {}, "admin-secret");
    eq((await h.call("GET", "/v1/square", undefined, d.pass)).status, 403);
    let last = 0;
    for (let i = 0; i < 11; i++) last = (await h.call("POST", "/v1/square", { topic: "questions", title: `Question number ${i} for the Square`, body: "Twenty characters of text at least." }, c.pass)).status;
    eq(last, 429, "ten posts an hour");
  });
}

Deno.test("names and targets: rules", () => {
  assert(validName("community-garden") && validName("a1b") && !validName("ab") && !validName("-ab") && !validName("ab-") && !validName("a--b") && !validName("olo"));
  assert(validOrigin("https://example.org") && !validOrigin("https://example.org/") && !validOrigin("https://EXAMPLE.org") && !validOrigin("http://example.org"));
  assert(validHost("anydesk.com") && validHost("a.b-c.co.uk") && validHost("192.168.1.20") && !validHost("999.1.1.1") && !validHost("localhost") && !validHost("bad host.com") && !validHost("-x.com"));
  assert(validTarget("https://example.org/x") && !validTarget("http://example.org") && !validTarget("https://localhost/") && !validTarget("https://10.0.0.1/") && !validTarget("https://user:pw@example.org") && !validTarget("javascript:alert(1)"));
});

Deno.test("pilot-town task templates are all accepted by the API", async () => {
  const h = await harness(new MemoryStore());
  const org = await h.join("pilot", "pilot_org");
  await h.call("POST", `/v1/admin/posters/${org.id}`, {}, "admin-secret");
  const file = JSON.parse(await Deno.readTextFile(new URL("../../pilot/tasks.json", import.meta.url)));
  assert(file.tasks.length >= 5);
  for (const t of file.tasks) {
    const fill = (x: string) => x.replaceAll("{town}", "Leeds").replaceAll("{area}", "Briggate");
    const r = await h.call("POST", "/v1/org/tasks", { title: fill(t.title), description: fill(t.description), instructions: fill(t.instructions), category: t.category, reward_pence: t.reward_pence, slots: t.slots }, org.pass);
    eq(r.status, 201, t.title);
    assert(t.minutes > 0 && t.reward_pence / (t.minutes / 60) >= 1300, `${t.title}: at least 13 pounds an hour`);
  }
});

await suite("memory", async () => new MemoryStore());

const pgUrl = Deno.env.get("POLNET_TEST_PG");
if (pgUrl) {
  const { PgStore } = await import("../supabase/functions/_shared/store_pg.ts");
  const stores: Array<{ close(): Promise<void> }> = [];
  await suite("postgres", async () => {
    const s = PgStore.connect(pgUrl);
    stores.push(s);
    // A clean slate for each test.
    await (s as any).sql`truncate polnet.reports, polnet.hits, polnet.claims, polnet.tasks, polnet.names, polnet.members cascade`.catch(() => undefined);
    return s;
  });
  Deno.test({ name: "postgres: close", sanitizeResources: false, fn: async () => { for (const s of stores) await s.close(); } });
}
