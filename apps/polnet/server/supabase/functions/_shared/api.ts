// The POL Net API: members (one real person, one account, through Proof-of-Life), the pol:// name
// registry only members can resolve, paid tasks posted by organisations and done by members, a ledger in
// pence, payouts through Stripe Connect, and member reports that take bad names and tasks down.
// Pure request handling over a Store, so the same code runs in the Edge Function, in tests and locally.

import { safeEqual, sign, type Signer, stripeSignatureOk, verify } from "./jwt.ts";
import { GROUPS, services } from "./services.ts";
import type { AlertKind, Claim, Comment, Member, PostRow, ReportKind, Store, Task } from "./store.ts";

export type Config = {
  /** This API's own address, the `iss` of member passes. */
  issuer: string;
  /** Proof-of-Life API (https://api.heliusnetwork.app) and POL Net's site keys there. */
  polApi: string;
  polSitekey: string;
  polSecret: string;
  adminSecret: string;
  /** Platform fee on funded tasks, in basis points of the rewards (1000 = 10%). Paid by the organisation, never taken from members. */
  feeBps: number;
  minPayoutPence: number;
  stripeSecret?: string;
  stripeWebhookSecret?: string;
  /** Where Stripe sends people back to (the join and payout pages live here too). */
  publicUrl: string;
  /** Lowest Proof-of-Life uniqueness accepted at join. */
  minUniqueness?: "none" | "device" | "history" | "vouched";
  /**
   * Opens the Square (posts, comments and votes by members). Off unless set: a place where people post to
   * each other is a user-to-user service under the UK Online Safety Act, and the risk assessments in
   * docs/WEBOCTA_SERVICES.md come before it opens.
   */
  squareOpen?: boolean;
  /** The eSIM store's address, once a supplier account exists. Until then the catalogue says "planned". */
  esimStoreUrl?: string;
  /** Local development only (scripts/dev.ts): lets pol:// names point at http://localhost. Never set in production. */
  allowLocalTargets?: boolean;
};

export type Deps = {
  store: Store;
  signer: Signer;
  config: Config;
  fetch?: typeof fetch;
  now?: () => number;
  id?: () => string;
};

const PASS_DAYS = 30;
const CLAIM_STALE_MS = 72 * 3600_000;
const REPORTS_TO_SUSPEND = 3;
export const CATEGORIES = ["environment", "health", "education", "community", "accessibility", "fact-checking", "translation", "local-data", "research"] as const;
const MAX_HELPERS = 3;
const INVITE_MS = 24 * 3600_000;
const ALERT_DAYS = 30;
const HUMAN_PASS_SECONDS = 300;
/** The Square's topics. "tv" is HeliusTV: a post that links to a video hosted elsewhere. */
export const TOPICS = ["ideas", "projects", "questions", "research", "impact", "tv"] as const;
export const ALERT_KINDS: readonly AlertKind[] = ["lookalike", "reported", "scam-page", "remote-access", "pause", "download"];
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const UNIQUENESS_ORDER = ["none", "device", "history", "vouched"];

export const RESERVED = new Set([
  "admin", "api", "app", "bank", "billing", "help", "helius", "heliusnetwork", "join", "login", "mail", "olo", "pay", "payments", "paypal",
  "pol", "polnet", "proof-of-life", "root", "security", "settings", "signin", "support", "system", "tasks", "wallet", "www", "zeus",
  "apple", "google", "microsoft", "amazon", "facebook", "meta", "hmrc", "gov", "nhs", "police", "stripe", "visa", "mastercard",
]);

export function validName(name: string): boolean {
  return /^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$/.test(name) && !name.includes("--") && !RESERVED.has(name);
}

export function validHandle(handle: string): boolean {
  return /^[a-z0-9_]{3,24}$/.test(handle) && !RESERVED.has(handle);
}

export function validTarget(url: string, allowLocal = false): boolean {
  try {
    const u = new URL(url);
    if (allowLocal && u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1")) return true;
    if (u.protocol !== "https:") return false;
    if (u.username || u.password) return false;
    const host = u.hostname;
    if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal")) return false;
    if (/^(10|127|0)\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || /^169\.254\./.test(host) || host.startsWith("[")) return false;
    return true;
  } catch {
    return false;
  }
}

/** An https origin exactly as a browser writes it (no path, no credentials, no private network). */
export function validOrigin(origin: string, allowLocal = false): boolean {
  try {
    const u = new URL(origin);
    return u.origin === origin && validTarget(`${origin}/`, allowLocal);
  } catch {
    return false;
  }
}

export function validHost(host: string): boolean {
  if (/^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/.test(host)) return true;
  return host.length <= 253 && /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/.test(host);
}

/** An invite code for a helper: 8 characters people can read out over the phone (no 0/O, 1/I/L). */
export function inviteCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const c = [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
  return `${c.slice(0, 4)}-${c.slice(4)}`;
}

const normCode = (code: string) => code.toUpperCase().replace(/[^A-Z0-9]/g, "");

class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers } });

function str(v: unknown, max: number, min = 0): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  if (t.length < min || t.length > max) return null;
  return t;
}

function int(v: unknown, lo: number, hi: number): number | null {
  return typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi ? v : null;
}

export function publicMember(m: Member) {
  return { id: m.id, handle: m.handle, role: m.role, payouts_enabled: m.payouts_enabled, has_payout_account: Boolean(m.stripe_account), created_at: m.created_at };
}

export function publicTask(t: Task, taken?: number) {
  return {
    id: t.id, title: t.title, description: t.description, instructions: t.instructions, category: t.category,
    reward_pence: t.reward_pence, currency: t.currency, slots: t.slots, slots_left: taken === undefined ? undefined : Math.max(0, t.slots - taken),
    status: t.status, deadline: t.deadline, created_at: t.created_at,
  };
}

export function createApi(deps: Deps) {
  const { store, signer, config } = deps;
  const f = deps.fetch ?? fetch;
  const now = deps.now ?? (() => Date.now());
  const newId = deps.id ?? (() => crypto.randomUUID());
  const iso = () => new Date(now()).toISOString();

  async function member(req: Request): Promise<Member> {
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!token) throw new HttpError(401, "pass_required", "Join POL Net to use this.");
    const claims = await verify(token, [signer.publicJwk], config.issuer, now());
    if (!claims || claims.typ !== "member" || typeof claims.sub !== "string") throw new HttpError(401, "pass_invalid", "Your member pass has expired. Open POL Net and join again.");
    const m = await store.memberById(claims.sub);
    if (!m) throw new HttpError(401, "pass_invalid");
    if (m.suspended) throw new HttpError(403, "member_suspended", "This membership is suspended. Contact support@heliusnetwork.com.");
    return m;
  }

  function admin(req: Request) {
    const auth = req.headers.get("authorization") ?? "";
    if (!config.adminSecret || !auth.startsWith("Bearer ") || !safeEqual(auth.slice(7), config.adminSecret)) throw new HttpError(401, "admin_only");
  }

  async function limit(key: string, perHour: number) {
    if (!(await store.hit(key, 3600_000, perHour, now()))) throw new HttpError(429, "rate_limited", "Too many requests. Try again later.");
  }

  async function body(req: Request): Promise<Record<string, unknown>> {
    try {
      const b = await req.json();
      return b && typeof b === "object" ? b as Record<string, unknown> : {};
    } catch {
      throw new HttpError(400, "bad_json");
    }
  }

  async function passFor(m: Member) {
    const iat = Math.floor(now() / 1000);
    return sign(signer, { iss: config.issuer, sub: m.id, typ: "member", handle: m.handle, iat, exp: iat + PASS_DAYS * 86400 });
  }

  async function stripe(path: string, params: Record<string, string>, idempotencyKey?: string) {
    if (!config.stripeSecret) throw new HttpError(503, "payments_not_configured", "Payments are not switched on yet.");
    const r = await f(`https://api.stripe.com/v1/${path}`, {
      method: Object.keys(params).length || path.endsWith("account_links") ? "POST" : "GET",
      headers: {
        authorization: `Bearer ${config.stripeSecret}`,
        "content-type": "application/x-www-form-urlencoded",
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
      },
      body: Object.keys(params).length ? new URLSearchParams(params).toString() : undefined,
    });
    const j = await r.json() as Record<string, unknown> & { error?: { message?: string } };
    if (!r.ok) throw new HttpError(502, "stripe_error", j.error?.message ?? `Stripe ${r.status}`);
    return j;
  }

  const taskTotal = (t: Pick<Task, "reward_pence" | "slots" | "fee_pence">) => t.reward_pence * t.slots + t.fee_pence;

  async function route(req: Request): Promise<Response> {
    const url = new URL(req.url);
    // The Edge Function is mounted at /functions/v1/polnet-api; everything after that is the route.
    const p = url.pathname.replace(/^.*\/polnet-api(?=\/|$)/, "") || "/";
    const m = req.method;
    const seg = p.split("/").filter(Boolean);

    if (m === "GET" && (p === "/" || p === "/v1/health")) return json({ ok: true, service: "polnet", time: iso() });
    if (m === "GET" && p === "/.well-known/jwks.json") return json({ keys: [signer.publicJwk] }, 200, { "cache-control": "public, max-age=300" });
    if (m === "GET" && p === "/v1/config") {
      return json({ pol_api: config.polApi, pol_sitekey: config.polSitekey, square: Boolean(config.squareOpen), topics: TOPICS, payouts: Boolean(config.stripeSecret), min_payout_pence: config.minPayoutPence, fee_bps: config.feeBps, categories: CATEGORIES, alert_kinds: ALERT_KINDS, max_helpers: MAX_HELPERS, join_url: `${config.publicUrl}/join` });
    }
    if (m === "GET" && p === "/v1/services") {
      const list = services({ feeBps: config.feeBps, esimStoreUrl: config.esimStoreUrl && validTarget(config.esimStoreUrl) ? config.esimStoreUrl : undefined, squareOpen: Boolean(config.squareOpen) });
      return json({ groups: GROUPS, services: list }, 200, { "cache-control": "public, max-age=300" });
    }
    if (m === "GET" && p === "/join") return new Response(joinPage(config), { headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": joinCsp(config) } });

    // --- Join: one real person, one account -------------------------------------------------------
    if (m === "POST" && p === "/v1/join") {
      const b = await body(req);
      const token = str(b.pol_token, 4096, 10);
      if (!token) throw new HttpError(400, "pol_token_required");
      const r = await f(`${config.polApi}/v1/siteverify`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ secret: config.polSecret, response: token, expected_action: "polnet_join" }) });
      const v = await r.json() as { success?: boolean; human?: boolean; subject?: string; uniqueness_level?: string; "error-codes"?: string[] };
      if (!v.success || !v.human || !v.subject) throw new HttpError(403, "not_verified", `Proof-of-Life did not pass${v["error-codes"]?.length ? ` (${v["error-codes"].join(", ")})` : ""}.`);
      const need = UNIQUENESS_ORDER.indexOf(config.minUniqueness ?? "device");
      if (UNIQUENESS_ORDER.indexOf(v.uniqueness_level ?? "none") < need) throw new HttpError(403, "uniqueness_too_low", "Proof-of-Life could not yet tell that you are one person on one device. Try again from your own phone.");
      await limit(`join:${v.subject}`, 20);
      let mem = await store.memberBySubject(v.subject);
      if (!mem) {
        const handle = str(b.handle, 24, 3)?.toLowerCase() ?? "";
        if (!validHandle(handle)) throw new HttpError(400, "handle_invalid", "Choose a handle of 3 to 24 lower-case letters, digits or underscores.");
        if (await store.memberByHandle(handle)) throw new HttpError(409, "handle_taken", "That handle is taken.");
        mem = await store.createMember({ id: newId(), subject: v.subject, handle, role: "member", suspended: false, stripe_account: null, payouts_enabled: false });
      }
      if (mem.suspended) throw new HttpError(403, "member_suspended");
      return json({ pass: await passFor(mem), member: publicMember(mem), returning: mem.created_at < iso().slice(0, 19) });
    }

    // --- Admin ---------------------------------------------------------------------------------------
    if (seg[0] === "v1" && seg[1] === "admin") {
      admin(req);
      if (m === "POST" && seg[2] === "posters" && seg[3]) {
        const mem = await store.updateMember(seg[3], { role: "poster" });
        return mem ? json({ member: publicMember(mem) }) : json({ error: "not_found" }, 404);
      }
      if (m === "POST" && seg[2] === "members" && seg[3] && (seg[4] === "suspend" || seg[4] === "restore")) {
        const mem = await store.updateMember(seg[3], { suspended: seg[4] === "suspend" });
        return mem ? json({ member: publicMember(mem) }) : json({ error: "not_found" }, 404);
      }
      if (m === "POST" && seg[2] === "names" && seg[3] && (seg[4] === "suspend" || seg[4] === "restore")) {
        await store.nameSetSuspended(seg[3], seg[4] === "suspend");
        return json({ name: await store.nameGet(seg[3]) });
      }
      if (m === "POST" && seg[2] === "posts" && seg[3] && (seg[4] === "remove" || seg[4] === "restore")) {
        return (await store.postSetRemoved(seg[3], seg[4] === "remove")) ? json({ post: seg[3], removed: seg[4] === "remove" }) : json({ error: "not_found" }, 404);
      }
      if (m === "POST" && seg[2] === "tasks" && seg[3] && seg[4] === "fund") {
        // Funding received another way (a bank transfer, a grant): the task opens.
        const t = await store.taskGet(seg[3]);
        if (!t) return json({ error: "not_found" }, 404);
        const updated = await store.taskUpdate(t.id, { funded_pence: taskTotal(t), status: "open" });
        return json({ task: updated });
      }
      throw new HttpError(404, "not_found");
    }

    // --- Stripe webhook (signed) ---------------------------------------------------------------------
    if (m === "POST" && p === "/v1/stripe/webhook") {
      const raw = await req.text();
      if (!config.stripeWebhookSecret || !(await stripeSignatureOk(raw, req.headers.get("stripe-signature") ?? "", config.stripeWebhookSecret, now()))) throw new HttpError(400, "bad_signature");
      const ev = JSON.parse(raw) as { type: string; data: { object: Record<string, unknown> } };
      const o = ev.data.object as { payment_status?: string; amount_total?: number; metadata?: Record<string, string>; id?: string; payouts_enabled?: boolean };
      if (ev.type === "checkout.session.completed" && o.payment_status === "paid" && o.metadata?.polnet_task) {
        const t = await store.taskGet(o.metadata.polnet_task);
        if (t && (o.amount_total ?? 0) >= taskTotal(t)) await store.taskUpdate(t.id, { funded_pence: o.amount_total ?? 0, status: "open" });
      }
      if (ev.type === "account.updated" && o.id && o.metadata?.polnet_member) {
        const mem = await store.memberById(o.metadata.polnet_member);
        if (mem && mem.stripe_account === o.id) await store.updateMember(mem.id, { payouts_enabled: Boolean(o.payouts_enabled) });
      }
      return json({ received: true });
    }

    // Everything below needs a member pass.
    const me = await member(req);
    await limit(`member:${me.id}`, 1200);

    if (m === "GET" && p === "/v1/me") return json({ member: publicMember(me), pass: await passFor(me) });

    // --- pol:// names: only members can resolve -----------------------------------------------------
    if (seg[0] === "v1" && seg[1] === "names") {
      if (m === "GET" && !seg[2]) return json({ names: await store.namesByOwner(me.id) });
      if (m === "POST" && !seg[2]) {
        await limit(`names:${me.id}`, 10);
        const b = await body(req);
        const name = str(b.name, 32, 3)?.toLowerCase() ?? "";
        const target = str(b.target, 2000, 9) ?? "";
        const description = str(b.description ?? "", 200) ?? "";
        if (!validName(name)) throw new HttpError(400, "name_invalid", "Names are 3 to 32 lower-case letters, digits and single hyphens, and some names are reserved.");
        if (!validTarget(target, config.allowLocalTargets)) throw new HttpError(400, "target_invalid", "The site address must be a public https:// address.");
        if ((await store.namesByOwner(me.id)).length >= 5) throw new HttpError(409, "name_limit", "A member can hold up to five names.");
        if (!(await store.nameCreate({ name, owner: me.id, target, description }))) throw new HttpError(409, "name_taken");
        return json({ name: await store.nameGet(name) }, 201);
      }
      if (m === "GET" && seg[2]) {
        const n = await store.nameGet(seg[2].toLowerCase());
        if (!n) throw new HttpError(404, "name_not_found", `pol://${seg[2]} is not registered.`);
        if (n.suspended) throw new HttpError(451, "name_suspended", `pol://${n.name} has been taken down after reports from members, pending review.`);
        const owner = await store.memberById(n.owner);
        return json({ name: n.name, target: n.target, description: n.description, owner: owner?.handle ?? null, created_at: n.created_at });
      }
      if (m === "DELETE" && seg[2] && !seg[3]) return json({ deleted: await store.nameDelete(me.id, seg[2].toLowerCase()) });
      if (m === "POST" && seg[2] && seg[3] === "visit") {
        // A ten-minute pass for one pol:// site. Its `sub` is pairwise (the same member looks different to
        // every site), and its type is "visit", so it is useless against this API if a site leaks it.
        const n = await store.nameGet(seg[2].toLowerCase());
        if (!n || n.suspended) throw new HttpError(n ? 451 : 404, n ? "name_suspended" : "name_not_found");
        const iat = Math.floor(now() / 1000);
        const visitor = await pairwise(me.id, n.name);
        return json({ visit: await sign(signer, { iss: config.issuer, aud: `pol://${n.name}`, sub: visitor, typ: "visit", iat, exp: iat + 600 }), expires_in: 600 });
      }
    }

    // --- Community safety list: hash prefixes, so the server never learns which site you are on --------
    if (m === "GET" && p === "/v1/safety") {
      const prefix = (url.searchParams.get("prefix") ?? "").toLowerCase();
      if (!/^[0-9a-f]{8}$/.test(prefix)) throw new HttpError(400, "prefix_invalid", "Send the first 8 hex characters of the SHA-256 of the host name.");
      const hosts = await store.reportedTargets("site", REPORTS_TO_SUSPEND);
      const hashes = await Promise.all(hosts.map(sha256hex));
      return json({ flagged: hashes.filter((h) => h.startsWith(prefix)) }, 200, { "cache-control": "private, max-age=600" });
    }

    // --- Tasks for members ----------------------------------------------------------------------------
    if (m === "GET" && p === "/v1/tasks") {
      const list = await store.tasks({ status: "open", limit: 100 });
      const withSlots = await Promise.all(list.map(async (t) => publicTask(t, await store.taskSlotsTaken(t.id))));
      const category = url.searchParams.get("category");
      return json({ tasks: withSlots.filter((t) => (t.slots_left ?? 0) > 0 && (!category || t.category === category)) });
    }
    if (m === "GET" && seg[0] === "v1" && seg[1] === "tasks" && seg[2] && !seg[3]) {
      const t = await store.taskGet(seg[2]);
      if (!t || (t.status === "draft" && t.poster !== me.id)) throw new HttpError(404, "task_not_found");
      return json({ task: publicTask(t, await store.taskSlotsTaken(t.id)) });
    }
    if (m === "POST" && seg[0] === "v1" && seg[1] === "tasks" && seg[2] && seg[3] === "claim") {
      await limit(`claim:${me.id}`, 30);
      const r = await store.claimCreate(seg[2], me.id, newId(), iso(), new Date(now() - CLAIM_STALE_MS).toISOString());
      if (r.error) throw new HttpError(r.error === "task_not_found" ? 404 : 409, r.error);
      return json({ claim: r.claim }, 201);
    }
    if (m === "GET" && p === "/v1/claims") {
      const claims = await store.claimsByMember(me.id);
      const tasks = await Promise.all(claims.map((c) => store.taskGet(c.task_id)));
      return json({ claims: claims.map((c, i) => ({ ...c, task: tasks[i] ? publicTask(tasks[i]!) : null })) });
    }
    if (m === "POST" && seg[0] === "v1" && seg[1] === "claims" && seg[2] && seg[3] === "submit") {
      const b = await body(req);
      const text = b.evidence_text === undefined ? null : str(b.evidence_text, 8000);
      const link = b.evidence_url === undefined || b.evidence_url === "" ? null : str(b.evidence_url, 2000);
      if (link !== null && !validTarget(link)) throw new HttpError(400, "evidence_url_invalid", "Evidence links must be public https:// addresses.");
      if (!text && !link) throw new HttpError(400, "evidence_required", "Describe what you did, or link to it.");
      const c = await store.claimSubmit(seg[2], me.id, { text, url: link }, iso());
      if (!c) throw new HttpError(409, "claim_not_submittable");
      return json({ claim: c });
    }

    // --- Organisations: post, fund, review -------------------------------------------------------------
    if (seg[0] === "v1" && seg[1] === "org") {
      if (me.role !== "poster") throw new HttpError(403, "poster_only", "Posting tasks needs an approved organisation account. Apply at support@heliusnetwork.com.");
      if (m === "GET" && p === "/v1/org/tasks") return json({ tasks: await store.tasks({ poster: me.id, limit: 200 }) });
      if (m === "POST" && p === "/v1/org/tasks") {
        await limit(`post:${me.id}`, 20);
        const b = await body(req);
        const title = str(b.title, 120, 5), description = str(b.description, 4000, 20), instructions = str(b.instructions ?? "", 4000) ?? "";
        const category = typeof b.category === "string" && (CATEGORIES as readonly string[]).includes(b.category) ? b.category : null;
        const reward = int(b.reward_pence, 50, 100_000), slots = int(b.slots, 1, 1000);
        const currency = b.currency === "EUR" ? "EUR" : b.currency === undefined || b.currency === "GBP" ? "GBP" : null;
        const deadline = b.deadline === undefined || b.deadline === null ? null : typeof b.deadline === "string" && !Number.isNaN(Date.parse(b.deadline)) && Date.parse(b.deadline) > now() ? new Date(b.deadline).toISOString() : undefined;
        if (!title || !description || !category || reward === null || slots === null || !currency || deadline === undefined) {
          throw new HttpError(400, "task_invalid", "A task needs a title (5 to 120 characters), a description (20 or more), a category, a reward of 50p to £1,000, 1 to 1,000 slots and, if given, a future deadline.");
        }
        const fee = Math.round(reward * slots * config.feeBps / 10_000);
        const t = await store.taskCreate({ id: newId(), poster: me.id, title, description, instructions, category, reward_pence: reward, currency, slots, status: "draft", deadline, fee_pence: fee, funded_pence: 0 });
        return json({ task: t, to_fund_pence: taskTotal(t) }, 201);
      }
      const t = seg[2] === "tasks" && seg[3] ? await store.taskGet(seg[3]) : null;
      if (seg[2] === "tasks" && seg[3] && (!t || t.poster !== me.id)) throw new HttpError(404, "task_not_found");
      if (m === "POST" && t && seg[4] === "fund") {
        if (t.status !== "draft") throw new HttpError(409, "already_funded");
        const s = await stripe("checkout/sessions", {
          mode: "payment",
          success_url: `${config.publicUrl}/funded?task=${t.id}`,
          cancel_url: `${config.publicUrl}/funded?task=${t.id}&cancelled=1`,
          "line_items[0][quantity]": "1",
          "line_items[0][price_data][currency]": t.currency.toLowerCase(),
          "line_items[0][price_data][unit_amount]": String(taskTotal(t)),
          "line_items[0][price_data][product_data][name]": `POL Net task: ${t.title}`.slice(0, 250),
          "metadata[polnet_task]": t.id,
        }, `fund-${t.id}`);
        return json({ checkout_url: s.url, total_pence: taskTotal(t) });
      }
      if (m === "POST" && t && seg[4] === "close") return json({ task: await store.taskUpdate(t.id, { status: "closed" }) });
      if (m === "GET" && t && seg[4] === "claims") return json({ claims: (await store.claimsByTask(t.id)).map(redactClaim) });
      if (m === "POST" && seg[2] === "claims" && seg[3] && (seg[4] === "approve" || seg[4] === "reject")) {
        const c = await store.claimGet(seg[3]);
        const task = c ? await store.taskGet(c.task_id) : null;
        if (!c || !task || task.poster !== me.id) throw new HttpError(404, "claim_not_found");
        if (seg[4] === "approve" && task.funded_pence < taskTotal(task)) throw new HttpError(409, "task_not_funded");
        const b = await body(req).catch(() => ({} as Record<string, unknown>));
        const note = str(b.note ?? "", 1000) || null;
        const approve = seg[4] === "approve";
        const reviewed = await store.claimReview(c.id, approve, note, iso(), approve ? { id: newId(), member_id: c.member_id, amount_pence: task.reward_pence, currency: task.currency, kind: "task_reward", ref: `claim:${c.id}` } : null);
        if (!reviewed) throw new HttpError(409, "claim_not_reviewable");
        return json({ claim: redactClaim(reviewed) });
      }
    }

    // --- Wallet and payouts ------------------------------------------------------------------------------
    if (m === "GET" && p === "/v1/wallet") {
      const [gbp, eur, entries] = await Promise.all([store.balance(me.id, "GBP"), store.balance(me.id, "EUR"), store.ledger(me.id, 100)]);
      return json({ balances: { GBP: gbp, EUR: eur }, entries, min_payout_pence: config.minPayoutPence, payouts: Boolean(config.stripeSecret), payouts_enabled: me.payouts_enabled });
    }
    if (m === "POST" && p === "/v1/payouts/onboard") {
      let account = me.stripe_account;
      if (!account) {
        const a = await stripe("accounts", { type: "express", "capabilities[transfers][requested]": "true", "metadata[polnet_member]": me.id }, `acct-${me.id}`);
        account = String(a.id);
        await store.updateMember(me.id, { stripe_account: account });
      }
      const link = await stripe("account_links", { account, type: "account_onboarding", refresh_url: `${config.publicUrl}/payouts?refresh=1`, return_url: `${config.publicUrl}/payouts?done=1` });
      return json({ onboarding_url: link.url });
    }
    if (m === "GET" && p === "/v1/payouts/status") {
      if (!me.stripe_account) return json({ payouts_enabled: false, has_payout_account: false });
      const a = await stripe(`accounts/${me.stripe_account}`, {});
      const enabled = Boolean(a.payouts_enabled);
      if (enabled !== me.payouts_enabled) await store.updateMember(me.id, { payouts_enabled: enabled });
      return json({ payouts_enabled: enabled, has_payout_account: true });
    }
    if (m === "POST" && p === "/v1/payouts") {
      await limit(`payout:${me.id}`, 6);
      if (!config.stripeSecret) throw new HttpError(503, "payments_not_configured", "Payouts are not switched on yet. Your balance is safe in the ledger.");
      if (!me.stripe_account || !me.payouts_enabled) throw new HttpError(409, "payout_account_needed", "Set up payouts first: Stripe checks your identity and bank account.");
      const b = await body(req);
      const currency = b.currency === "EUR" ? "EUR" : "GBP";
      const balance = await store.balance(me.id, currency);
      const amount = b.amount_pence === undefined ? balance : int(b.amount_pence, 1, 10_000_000);
      if (amount === null || amount < config.minPayoutPence) throw new HttpError(400, "below_minimum", `The smallest payout is ${(config.minPayoutPence / 100).toFixed(2)}.`);
      const ref = newId();
      if (!(await store.payoutDebit({ id: ref, member_id: me.id, amount_pence: -amount, currency, kind: "payout", ref: `payout:${ref}` }))) throw new HttpError(409, "insufficient_balance");
      try {
        const tr = await stripe("transfers", { amount: String(amount), currency: currency.toLowerCase(), destination: me.stripe_account, "metadata[polnet_member]": me.id, "metadata[polnet_payout]": ref }, `payout-${ref}`);
        return json({ paid_pence: amount, currency, transfer: tr.id }, 201);
      } catch (e) {
        await store.ledgerAdd({ id: newId(), member_id: me.id, amount_pence: amount, currency, kind: "payout_reversal", ref: `payout:${ref}` });
        throw e;
      }
    }

    // --- Family help: helpers hear about scam warnings (host and kind only), nothing else ----------------
    if (seg[0] === "v1" && seg[1] === "helpers") {
      if (m === "POST" && seg[2] === "invite") {
        await limit(`invite:${me.id}`, 10);
        if ((await store.helpersOf(me.id)).length >= MAX_HELPERS) throw new HttpError(409, "helper_limit", `You can have up to ${MAX_HELPERS} helpers.`);
        const code = inviteCode();
        const expires = new Date(now() + INVITE_MS).toISOString();
        await store.helperInviteCreate(await sha256hex(`polnet-invite:${normCode(code)}`), me.id, expires);
        return json({ code, expires_at: expires }, 201);
      }
      if (m === "POST" && seg[2] === "accept") {
        await limit(`accept:${me.id}`, 20);
        const b = await body(req);
        const code = normCode(str(b.code, 20, 8) ?? "");
        if (code.length !== 8) throw new HttpError(400, "code_invalid", "Type the 8-character code exactly as it was given to you.");
        const inviter = await store.helperInviteTake(await sha256hex(`polnet-invite:${code}`), iso());
        if (!inviter) throw new HttpError(404, "code_unknown", "That code is not valid or has expired. Ask for a new one.");
        if (inviter === me.id) throw new HttpError(400, "own_code", "That is your own code: give it to the person who will help you.");
        const who = await store.memberById(inviter);
        if (!who || who.suspended) throw new HttpError(404, "code_unknown");
        if (!(await store.helperLink({ id: newId(), protected_id: inviter, helper_id: me.id }, MAX_HELPERS))) throw new HttpError(409, "link_exists", "You already help this person, or they have the most helpers allowed.");
        return json({ helping: who.handle }, 201);
      }
      if (m === "GET" && !seg[2]) {
        const [mine, theirs] = await Promise.all([store.helpersOf(me.id), store.helping(me.id)]);
        const handle = async (id: string) => (await store.memberById(id))?.handle ?? "former member";
        return json({
          helpers: await Promise.all(mine.map(async (l) => ({ id: l.id, handle: await handle(l.helper_id), since: l.created_at }))),
          helping: await Promise.all(theirs.map(async (l) => ({ id: l.id, handle: await handle(l.protected_id), since: l.created_at }))),
        });
      }
      if (m === "DELETE" && seg[2] && !seg[3]) return json({ ended: await store.helperUnlink(seg[2], me.id) });
      if (m === "POST" && seg[2] === "alerts") {
        await limit(`alert:${me.id}`, 30);
        const b = await body(req);
        const host = (str(b.host, 253, 3) ?? "").toLowerCase();
        const kind = ALERT_KINDS.find((k) => k === b.kind);
        if (!validHost(host) || !kind) throw new HttpError(400, "alert_invalid");
        const helpers = await store.helpersOf(me.id);
        if (helpers.length === 0) return json({ sent: 0 });
        await store.helperAlertAdd({ id: newId(), protected_id: me.id, host, kind }, iso(), new Date(now() - ALERT_DAYS * 86400_000).toISOString());
        return json({ sent: helpers.length }, 201);
      }
      if (m === "GET" && seg[2] === "alerts") {
        const rows = await store.helperAlertsFor(me.id, new Date(now() - ALERT_DAYS * 86400_000).toISOString(), 100);
        const handles = new Map<string, string>();
        for (const r of rows) if (!handles.has(r.protected_id)) handles.set(r.protected_id, (await store.memberById(r.protected_id))?.handle ?? "former member");
        return json({ alerts: rows.map((r) => ({ handle: handles.get(r.protected_id), host: r.host, kind: r.kind, at: r.created_at })) });
      }
    }

    // --- The Square: the members' community (and HeliusTV, its "tv" topic) -------------------------------
    if (seg[0] === "v1" && seg[1] === "square") {
      if (!config.squareOpen) throw new HttpError(503, "square_not_open", "The Square is not open yet.");
      const handles = new Map<string, string>();
      const handleOf = async (id: string) => {
        if (!handles.has(id)) handles.set(id, (await store.memberById(id))?.handle ?? "former member");
        return handles.get(id)!;
      };
      const showPost = async (r: PostRow, voted: boolean) => ({ id: r.id, topic: r.topic, title: r.title, body: r.body, link: r.link, author: await handleOf(r.author), mine: r.author === me.id, votes: r.votes, comments: r.comments, voted, created_at: r.created_at });
      const showComment = async (c: Comment) => ({ id: c.id, body: c.body, author: await handleOf(c.author), mine: c.author === me.id, created_at: c.created_at });

      if (m === "GET" && !seg[2]) {
        const topic = url.searchParams.get("topic") ?? "";
        if (topic && !(TOPICS as readonly string[]).includes(topic)) throw new HttpError(400, "topic_invalid");
        const rows = await store.posts({ topic: topic || undefined, sort: url.searchParams.get("sort") === "top" ? "top" : "new", limit: 50 });
        const mine = new Set(await store.voted(me.id, rows.map((r) => r.id)));
        return json({ topics: TOPICS, posts: await Promise.all(rows.map((r) => showPost(r, mine.has(r.id)))) });
      }
      if (m === "POST" && !seg[2]) {
        await limit(`post-square:${me.id}`, 10);
        const b = await body(req);
        const topic = (TOPICS as readonly string[]).includes(String(b.topic)) ? String(b.topic) : null;
        const title = str(b.title, 140, 5);
        const text = str(b.body ?? "", 6000);
        const link = b.link === undefined || b.link === null || b.link === "" ? null : str(b.link, 2000, 9);
        if (!topic || !title || text === null) throw new HttpError(400, "post_invalid", "A post needs a topic, a title of 5 to 140 characters and up to 6,000 characters of text.");
        if (link !== null && !validTarget(link)) throw new HttpError(400, "link_invalid", "Links must be public https:// addresses.");
        if (topic === "tv" && !link) throw new HttpError(400, "link_required", "A HeliusTV post needs the https:// address of the video.");
        if (topic !== "tv" && text.length < 20) throw new HttpError(400, "post_invalid", "Say a little more: at least 20 characters.");
        const created = await store.postCreate({ id: newId(), author: me.id, topic, title, body: text, link }, iso());
        return json({ post: await showPost({ ...created, votes: 0, comments: 0 }, false) }, 201);
      }
      if (m === "DELETE" && seg[2] === "comments" && seg[3] && !seg[4]) return json({ deleted: await store.commentDelete(seg[3], me.id) });
      const row = seg[2] && seg[2] !== "comments" ? await store.postGet(seg[2]) : null;
      if (seg[2] && seg[2] !== "comments") {
        if (!row) throw new HttpError(404, "post_not_found");
        if (row.removed && m !== "DELETE") throw new HttpError(451, "post_removed", "This post was taken down after reports from members, pending review.");
        if (m === "GET" && !seg[3]) {
          const [list, mine] = await Promise.all([store.comments(row.id, 200), store.voted(me.id, [row.id])]);
          return json({ post: await showPost(row, mine.length === 1), comments: await Promise.all(list.map(showComment)) });
        }
        if (m === "DELETE" && !seg[3]) return json({ deleted: await store.postDelete(row.id, me.id) });
        if (m === "POST" && seg[3] === "vote") {
          await limit(`vote:${me.id}`, 300);
          const b = await body(req).catch(() => ({} as Record<string, unknown>));
          const on = b.on !== false;
          return json({ votes: await store.voteSet(row.id, me.id, on), voted: on });
        }
        if (m === "POST" && seg[3] === "comments") {
          await limit(`comment:${me.id}`, 60);
          const b = await body(req);
          const text = str(b.body, 3000, 1);
          if (!text) throw new HttpError(400, "comment_invalid", "A comment is 1 to 3,000 characters.");
          const c = await store.commentCreate({ id: newId(), post_id: row.id, author: me.id, body: text }, iso());
          if (!c) throw new HttpError(404, "post_not_found");
          return json({ comment: await showComment(c) }, 201);
        }
      }
    }

    // --- Trust tools: "a real person" for any https site, with consent, unlinkable across sites ----------
    if (m === "POST" && p === "/v1/human") {
      await limit(`human:${me.id}`, 120);
      const b = await body(req);
      const origin = str(b.origin, 300, 9) ?? "";
      const nonce = str(b.nonce, 128, 8) ?? "";
      if (!validOrigin(origin, config.allowLocalTargets)) throw new HttpError(400, "origin_invalid", "The site must be a public https:// origin.");
      if (!/^[A-Za-z0-9_-]{8,128}$/.test(nonce)) throw new HttpError(400, "nonce_invalid", "The site's nonce must be 8 to 128 letters, digits, - or _.");
      const iat = Math.floor(now() / 1000);
      const sub = (await sha256hex(`polnet-human:${me.id}:${origin}`)).slice(0, 32);
      const pass = await sign(signer, { iss: config.issuer, aud: origin, sub, typ: "human", nonce, iat, exp: iat + HUMAN_PASS_SECONDS });
      return json({ human: pass, expires_in: HUMAN_PASS_SECONDS });
    }

    // --- Reports: members take bad things down ----------------------------------------------------------
    if (m === "POST" && p === "/v1/reports") {
      await limit(`report:${me.id}`, 30);
      const b = await body(req);
      const kind = (["name", "task", "member", "site", "post"] as const).find((k) => k === b.kind) as ReportKind | undefined;
      const target = str(b.target, 2000, 1);
      const reason = str(b.reason, 1000, 3);
      if (!kind || !target || !reason) throw new HttpError(400, "report_invalid");
      const count = await store.report({ id: newId(), reporter: me.id, kind, target, reason, created_at: iso() });
      let action: string | null = null;
      if (kind === "site") {
        // Sites are reported by host name, so the safety list can be checked by hash.
        try {
          const host = new URL(/^https?:\/\//.test(target) ? target : `https://${target}`).hostname;
          if (host !== target) {
            const again = await store.report({ id: newId(), reporter: me.id, kind, target: host, reason, created_at: iso() });
            return json({ received: true, reports: again, action: again >= REPORTS_TO_SUSPEND ? "site_flagged" : null }, 201);
          }
        } catch {
          throw new HttpError(400, "report_invalid");
        }
        if (count >= REPORTS_TO_SUSPEND) action = "site_flagged";
      }
      if (count >= REPORTS_TO_SUSPEND && kind === "name") {
        await store.nameSetSuspended(target.toLowerCase(), true);
        action = "name_suspended";
      }
      if (count >= REPORTS_TO_SUSPEND && kind === "task") {
        const t = await store.taskGet(target);
        if (t && t.status === "open") {
          await store.taskUpdate(t.id, { status: "closed" });
          action = "task_closed";
        }
      }
      if (count >= REPORTS_TO_SUSPEND && kind === "post" && (await store.postSetRemoved(target, true))) action = "post_removed";
      return json({ received: true, reports: count, action }, 201);
    }

    throw new HttpError(404, "not_found");
  }

  return async function handle(req: Request): Promise<Response> {
    try {
      return await route(req);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.code, message: e.message }, e.status);
      console.error("[polnet]", e);
      return json({ error: "server_error", message: "Something went wrong." }, 500);
    }
  };
}

export async function sha256hex(s: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The member's id as one pol:// site sees it: stable for that site, unlinkable across sites. */
async function pairwise(memberId: string, name: string): Promise<string> {
  return (await sha256hex(`polnet-visitor:${memberId}:${name}`)).slice(0, 32);
}

/** What a poster sees of a claim: the work, never who the member is beyond their handle-free id. */
function redactClaim(c: Claim) {
  return { id: c.id, task_id: c.task_id, member: c.member_id.slice(0, 8), status: c.status, evidence_text: c.evidence_text, evidence_url: c.evidence_url, note: c.note, submitted_at: c.submitted_at, reviewed_at: c.reviewed_at };
}

function joinCsp(c: Config): string {
  const pol = new URL(c.polApi).origin;
  return `default-src 'none'; script-src 'self' 'unsafe-inline' https://cdn.heliusnetwork.app; connect-src 'self' ${pol}; frame-src ${pol} https://check.heliusnetwork.app; img-src data: https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`;
}

/**
 * The join page for local development (scripts/dev.ts). In production the page is served by the Netlify
 * site in apps/polnet/proxy, because Supabase serves HTML from Edge Functions on its domain as plain text.
 * The join page the browser opens: one Proof-of-Life check, a handle, done. The pass goes back to the
 * POL Net browser through the bridge its join window exposes (window.polnetBrowser), and nowhere else.
 */
function joinPage(c: Config): string {
  const esc = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Join POL Net</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:520px;margin:48px auto;padding:0 20px;color:#111;background:#fafaf7}h1{font-weight:600}input{font:inherit;padding:10px;width:100%;box-sizing:border-box;border:1px solid #bbb;border-radius:8px}button{font:inherit;padding:10px 18px;border-radius:8px;border:0;background:#0a84ff;color:#fff;margin-top:12px}small{color:#666}#msg{margin-top:16px}</style>
<script src="https://cdn.heliusnetwork.app/pol/v1/gate.js" async defer></script></head><body>
<h1>Join POL Net</h1><p>One check that you are a real person, then choose a handle. No email, no name, no phone number is kept: only an id that links to nothing else, and the handle you choose.</p>
<label>Handle<br><input id="handle" maxlength="24" autocomplete="off" placeholder="e.g. river_fox"></label><small>3 to 24 lower-case letters, digits or underscores. Others see this, nothing else.</small>
<div style="margin-top:20px" id="pol" data-sitekey="${esc(c.polSitekey)}" data-action="polnet_join"></div>
<div id="msg" role="status"></div>
<script>
const msg=document.getElementById('msg');
function done(token){
  const handle=document.getElementById('handle').value.trim().toLowerCase();
  msg.textContent='Checking...';
  fetch('/v1/join'.replace(/^/, location.pathname.replace(/\\/join$/, '')),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({pol_token:token,handle})})
    .then(r=>r.json()).then(j=>{
      if(!j.pass){msg.textContent=j.message||j.error||'That did not work. Try again.';return;}
      msg.textContent='Welcome, '+j.member.handle+'. You can close this window.';
      if(window.polnetBrowser&&window.polnetBrowser.complete) window.polnetBrowser.complete(j.pass);
    }).catch(()=>{msg.textContent='POL Net could not be reached. Try again.';});
}
window.addEventListener('load',()=>{ if(window.PoL&&window.PoL.render) window.PoL.render(document.getElementById('pol'),{callback:done}); else msg.textContent='The Proof-of-Life check could not load.'; });
</script></body></html>`;
}
