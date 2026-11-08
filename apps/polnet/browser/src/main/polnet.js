"use strict";
/**
 * The browser's side of the POL Net protocol, stage 1: member passes, pol:// names resolved through the
 * registry only members can read, a ten-minute pairwise visit pass for each pol:// site, and the
 * community safety list checked by hash prefix. `fetch` is passed in so this is tested without Electron.
 */

/** What the browser's own pages (polnet://tasks, wallet, names) may ask the API for. Nothing else gets through. */
const ALLOWED = [
  ["GET", /^\/v1\/(me|config|tasks|claims|wallet|names|org\/tasks|payouts\/status)$/],
  ["GET", /^\/v1\/tasks\/[0-9a-f-]{36}$/],
  ["GET", /^\/v1\/org\/tasks\/[0-9a-f-]{36}\/claims$/],
  ["POST", /^\/v1\/tasks\/[0-9a-f-]{36}\/claim$/],
  ["POST", /^\/v1\/claims\/[0-9a-f-]{36}\/submit$/],
  ["POST", /^\/v1\/(names|reports|payouts|payouts\/onboard|org\/tasks)$/],
  ["POST", /^\/v1\/org\/tasks\/[0-9a-f-]{36}\/(fund|close)$/],
  ["POST", /^\/v1\/org\/claims\/[0-9a-f-]{36}\/(approve|reject)$/],
  ["DELETE", /^\/v1\/names\/[a-z0-9-]{3,32}$/],
];

function allowedApi(method, path) {
  const [p] = String(path).split("?");
  return ALLOWED.some(([m, re]) => m === method && re.test(p));
}

/** pol://community-garden/events?x=1 -> { name: "community-garden", path: "/events?x=1" }, or null. */
function parsePolUrl(url) {
  const m = /^pol:\/\/([a-z0-9-]{3,32})(\/[^#]*)?(#.*)?$/i.exec(String(url));
  if (!m) return null;
  return { name: m[1].toLowerCase(), path: m[2] || "/" };
}

class PolNet {
  constructor({ server, pass, fetch: f }) {
    this.server = server;
    this.pass = pass;
    this.f = f;
    this.names = new Map();
    this.flagCache = new Map();
  }

  async call(method, path, body, { auth = true } = {}) {
    const headers = { "content-type": "application/json" };
    const pass = typeof this.pass === "function" ? this.pass() : this.pass;
    if (auth && pass) headers.authorization = `Bearer ${pass}`;
    let r;
    try {
      r = await this.f(`${this.server()}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    } catch {
      return { status: 0, error: "unreachable", message: "The POL Net server could not be reached. Check your connection, or the server address in Settings." };
    }
    let j = {};
    try {
      j = await r.json();
    } catch {
      j = { error: "bad_response" };
    }
    return { status: r.status, ...j };
  }

  /** The registry record for a pol:// name (cached for five minutes). */
  async resolve(name) {
    const hit = this.names.get(name);
    if (hit && Date.now() - hit.at < 300_000) return hit.record;
    const record = await this.call("GET", `/v1/names/${encodeURIComponent(name)}`);
    if (record.status === 200) this.names.set(name, { at: Date.now(), record });
    return record;
  }

  async visitPass(name) {
    const r = await this.call("POST", `/v1/names/${encodeURIComponent(name)}/visit`, {});
    return r.status === 200 ? r.visit : null;
  }

  /** True when members have flagged this host. Only an 8-character hash prefix leaves the computer. */
  async flagged(host, hostHash) {
    const full = hostHash(host);
    const prefix = full.slice(0, 8);
    let list = this.flagCache.get(prefix);
    if (!list || Date.now() - list.at > 600_000) {
      const r = await this.call("GET", `/v1/safety?prefix=${prefix}`);
      list = { at: Date.now(), hashes: r.status === 200 ? r.flagged || [] : [] };
      this.flagCache.set(prefix, list);
    }
    return list.hashes.includes(full);
  }
}

module.exports = { PolNet, allowedApi, parsePolUrl };
