"use strict";
/**
 * POL Net Shields: the privacy rules every request passes through. Pure functions, no Electron, so they
 * are unit tested with `node --test`. The main process wires them to session.webRequest.
 *
 *  - Trackers and surveillance ads are cancelled (lists/trackers.txt, host or any subdomain).
 *  - Tracking parameters are stripped from addresses (utm_*, fbclid, gclid and their kind).
 *  - Plain http:// is upgraded to https://, except for this computer and the local network.
 *  - Third-party cookies are neither sent nor stored.
 *  - Every request says Sec-GPC: 1 (Global Privacy Control) and DNT: 1.
 */

const fs = require("node:fs");
const path = require("node:path");

/** Second-level suffixes under which a registrable domain has three labels (example.co.uk). */
const TWO_PART_SUFFIXES = new Set([
  "co.uk", "org.uk", "gov.uk", "ac.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "nhs.uk", "police.uk", "sch.uk",
  "com.au", "net.au", "org.au", "gov.au", "edu.au", "co.nz", "org.nz", "govt.nz", "co.jp", "ne.jp", "or.jp", "ac.jp",
  "co.za", "org.za", "gov.za", "com.br", "com.mx", "com.tr", "com.cn", "com.hk", "com.sg", "com.my", "co.in", "gov.in",
  "co.kr", "co.il", "com.ar", "com.co", "com.pk", "com.ng", "co.ke", "com.eg", "com.sa", "com.ua", "co.id",
]);

/** The registrable domain ("site") of a host: news.bbc.co.uk -> bbc.co.uk, a.b.example.com -> example.com. */
function siteOf(host) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  if (!h || /^\d+\.\d+\.\d+\.\d+$/.test(h) || h.includes(":")) return h;
  const parts = h.split(".");
  if (parts.length <= 2) return h;
  const lastTwo = parts.slice(-2).join(".");
  return TWO_PART_SUFFIXES.has(lastTwo) ? parts.slice(-3).join(".") : lastTwo;
}

function loadList(file) {
  const text = fs.readFileSync(file, "utf8");
  const hosts = new Set();
  for (const raw of text.split("\n")) {
    const line = raw.trim().toLowerCase();
    if (!line || line.startsWith("#") || line.includes("/") || line.includes(" ")) continue;
    hosts.add(line);
  }
  return hosts;
}

let defaultList = null;
function trackerList() {
  if (!defaultList) defaultList = loadList(path.join(__dirname, "..", "..", "lists", "trackers.txt"));
  return defaultList;
}

/** True when the host or one of its parent domains is on the list. */
function isTracker(host, list = trackerList()) {
  let h = String(host || "").toLowerCase();
  while (h) {
    if (list.has(h)) return true;
    const dot = h.indexOf(".");
    if (dot < 0) return false;
    h = h.slice(dot + 1);
  }
  return false;
}

const TRACKING_PARAMS = new Set([
  "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id", "igshid", "igsh",
  "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id",
  "vero_id", "vero_conv", "s_cid", "ncid", "sr_share", "spm", "scm", "_openstat", "rb_clickid", "ef_id", "srsltid", "si",
]);

/** The address without tracking parameters, or null when there was nothing to strip. */
function stripTrackingParams(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  let changed = false;
  for (const key of [...u.searchParams.keys()]) {
    const k = key.toLowerCase();
    // "si" is YouTube and Spotify's share tracker; only stripped on those sites, where it is never content.
    if (k === "si" && !/(^|\.)(youtube\.com|youtu\.be|spotify\.com)$/.test(u.hostname)) continue;
    if (k.startsWith("utm_") || TRACKING_PARAMS.has(k)) {
      u.searchParams.delete(key);
      changed = true;
    }
  }
  return changed ? u.toString() : null;
}

function isLocalHost(host) {
  const h = String(host || "").toLowerCase();
  return h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal") || h.endsWith(".lan") || h.endsWith(".home.arpa")
    || /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || /^169\.254\./.test(h) || h.startsWith("[") || /^\d+\.\d+\.\d+\.\d+$/.test(h);
}

/** The https:// address for a plain http:// one (null when it should stay as it is). */
function httpsUpgrade(url, exceptions = new Set()) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" || isLocalHost(u.hostname) || exceptions.has(u.hostname)) return null;
  u.protocol = "https:";
  if (u.port === "80") u.port = "";
  return u.toString();
}

/**
 * What to do with one request.
 * @param {{url: string, resourceType?: string, topUrl?: string|null, shieldsOn?: boolean, httpExceptions?: Set<string>, list?: Set<string>}} r
 * @returns {{cancel: true, reason: string} | {redirectURL: string, reason: string} | {}}
 */
function decide(r) {
  let u;
  try {
    u = new URL(r.url);
  } catch {
    return {};
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return {};
  const mainFrame = r.resourceType === "mainFrame";
  if (r.shieldsOn !== false) {
    let topSite = null;
    try {
      topSite = r.topUrl ? siteOf(new URL(r.topUrl).hostname) : null;
    } catch {
      topSite = null;
    }
    // A tracker is blocked as a third party; opening its own site on purpose still works.
    if (!mainFrame && isTracker(u.hostname, r.list) && siteOf(u.hostname) !== topSite) return { cancel: true, reason: "tracker" };
    if (mainFrame) {
      const stripped = stripTrackingParams(r.url);
      if (stripped) return { redirectURL: httpsUpgrade(stripped, r.httpExceptions) || stripped, reason: "tracking-params" };
    }
  }
  const upgraded = httpsUpgrade(r.url, r.httpExceptions);
  if (upgraded) return { redirectURL: upgraded, reason: "https" };
  return {};
}

/** True when a request goes to a different site from the page that made it. */
function isThirdParty(requestUrl, topUrl) {
  try {
    if (!topUrl) return false;
    const top = new URL(topUrl);
    if (top.protocol !== "http:" && top.protocol !== "https:") return false;
    return siteOf(new URL(requestUrl).hostname) !== siteOf(top.hostname);
  } catch {
    return false;
  }
}

/** Request headers with privacy signals added and third-party cookies removed. */
function privacyHeaders(headers, { thirdParty, shieldsOn = true }) {
  const out = { ...headers };
  out["Sec-GPC"] = "1";
  out["DNT"] = "1";
  delete out["X-Client-Data"];
  if (shieldsOn && thirdParty) {
    for (const k of Object.keys(out)) if (k.toLowerCase() === "cookie") delete out[k];
  }
  return out;
}

/** Response headers with third-party Set-Cookie removed. */
function stripThirdPartySetCookie(headers, { thirdParty, shieldsOn = true }) {
  if (!shieldsOn || !thirdParty || !headers) return headers;
  const out = {};
  for (const [k, v] of Object.entries(headers)) if (k.toLowerCase() !== "set-cookie") out[k] = v;
  return out;
}

module.exports = { siteOf, loadList, trackerList, isTracker, stripTrackingParams, isLocalHost, httpsUpgrade, decide, isThirdParty, privacyHeaders, stripThirdPartySetCookie };
