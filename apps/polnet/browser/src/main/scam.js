"use strict";
/**
 * Scam protection beyond lookalike addresses: what the page says, what the site is for, and a pause
 * before the moments scammers rush people through (typing a password or card number on a site you
 * have never used, letting a stranger control your computer).
 *
 * Pure functions, so they are tested without Electron. The main process reads the page text in an
 * isolated world (the page cannot see or change the check) and shows the warning page.
 *
 * Principles: warn, never silently block; explain the trick in plain words; always offer a way back.
 */

/** Remote-control tools. Real and useful, and also the first thing a "tech support" or "bank" scammer asks for. */
const REMOTE_ACCESS = [
  "anydesk.com", "teamviewer.com", "ultraviewer.net", "rustdesk.com", "supremocontrol.com", "splashtop.com", "logmein.com",
  "logmeininc.com", "gotomypc.com", "screenconnect.com", "connectwise.com", "zoho.com/assist", "assist.zoho.com", "zohoassist.com",
  "remotepc.com", "islonline.com", "getscreen.me", "aeroadmin.com", "ammyy.com", "showmypc.com", "fixme.it", "beamyourscreen.com",
  "remoteutilities.com", "dwservice.net", "parsec.app",
];

function remoteAccessSite(host, pathname = "/") {
  const h = String(host || "").toLowerCase();
  for (const entry of REMOTE_ACCESS) {
    const [domain, path] = entry.split(/(?=\/)/);
    if ((h === domain || h.endsWith(`.${domain}`)) && (!path || String(pathname).toLowerCase().startsWith(path))) return domain;
  }
  return null;
}

/**
 * Patterns scam pages use, each with the plain explanation shown to the person. Weights add up; one
 * strong signal is not enough on its own, so ordinary pages that mention "virus" or "gift card" pass.
 */
const SIGNALS = [
  { id: "fake-virus", weight: 2, re: /\b(your (computer|pc|device|mac|iphone|phone) (is|has been) (infected|locked|blocked|compromised|hacked)|virus(es)? (detected|found) on your (computer|device|pc)|(trojan|spyware|malware) (detected|alert))/i,
    why: "It says your computer is infected or locked. Real warnings come from your own antivirus, never from a web page." },
  { id: "call-support", weight: 2, re: /\b(call|contact|ring|phone)\b.{0,40}\b(microsoft|apple|windows|google|amazon|norton|mcafee|tech(nical)?) (support|help ?desk|security|team)\b/i,
    why: "It asks you to phone a support line. Microsoft, Apple and banks never put a phone number in a pop-up warning." },
  { id: "toll-free", weight: 1, re: /(\+?1[\s.-]?\(?8(00|33|44|55|66|77|88)\)?[\s.-]?\d{3}[\s.-]?\d{4})|(\b0800[\s.-]?\d{3}[\s.-]?\d{3,4}\b)/,
    why: "It shows a free-phone number next to a warning." },
  { id: "do-not-close", weight: 1, re: /\b(do not (close|restart|shut down|turn off)|don'?t (close|restart|shut down) (this|your))/i,
    why: "It tells you not to close the page. Closing it is always safe." },
  { id: "gift-cards", weight: 3, re: /\b(pay|payment|settle|fee|fine|tax|deposit)\b.{0,60}\b(gift ?cards?|itunes cards?|google play cards?|steam cards?|amazon (gift )?vouchers?)\b|\b(gift ?cards?|itunes cards?|google play cards?|steam cards?)\b.{0,60}\b(to pay|as payment|for payment)\b/i,
    why: "It asks for payment in gift cards. No real company, tax office or court takes gift cards." },
  { id: "crypto-doubling", weight: 4, re: /\b(send|deposit|transfer)\b.{0,40}\b(btc|eth|bitcoin|ether|usdt|sol|crypto)\b.{0,80}\b(get|receive|we('| wi)ll send)\b.{0,30}\b(double|2x|twice|back)\b|\bdouble your (btc|eth|bitcoin|crypto|money)\b/i,
    why: "It promises to send back more crypto than you send. That is always a scam, whoever the page says it is." },
  { id: "safe-account", weight: 4, re: /\b(move|transfer)\b.{0,40}\b(money|funds|savings)\b.{0,40}\b(safe|secure|protected|holding) account\b/i,
    why: "It asks you to move money to a \"safe account\". Banks and the police never ask you to do that." },
  { id: "prize", weight: 1, re: /\b(congratulations|you('ve| have) (won|been selected)|claim your (prize|reward|winnings))\b/i,
    why: "It says you have won something you did not enter." },
  { id: "fee-to-release", weight: 2, re: /\b(small|delivery|customs|release|processing|redelivery) fee\b.{0,60}\b(card|pay|payment)\b/i,
    why: "It asks for a small fee to release a parcel or a prize. Parcel scams use a small fee to collect card details." },
  { id: "urgent", weight: 1, re: /\b(within (24|48) hours|immediately|urgent(ly)?|final (notice|warning)|account (will be )?(suspended|closed|locked))\b/i,
    why: "It rushes you. Scams create panic so you act before you think." },
  { id: "seed-phrase", weight: 3, re: /\b(enter|type|confirm|verify|import|sync)\b.{0,40}\b(seed phrase|recovery phrase|secret recovery|12[- ]word|24[- ]word|mnemonic)\b/i,
    why: "It asks for a wallet's recovery phrase. Anyone who has it can take everything in the wallet; no real service ever asks for it." },
];

const THRESHOLD = 4;

/**
 * Looks at the visible text of a page. Returns null for an ordinary page, or the matched signals with
 * their explanations when they add up to a likely scam.
 */
function scamPage(text) {
  const t = String(text || "").slice(0, 30000).replace(/\s+/g, " ");
  if (t.length < 20) return null;
  const hits = SIGNALS.filter((s) => s.re.test(t));
  const score = hits.reduce((n, s) => n + s.weight, 0);
  if (score < THRESHOLD) return null;
  return { score, signals: hits.map((s) => s.id), reasons: hits.map((s) => s.why) };
}

/**
 * What a page asks for. Computed in the page (isolated world) by PAGE_PROBE and judged here: a password
 * or payment card field on a site the person has not used before is the moment to pause.
 */
const PAGE_PROBE = `(() => {
  const inputs = [...document.querySelectorAll("input")];
  const password = inputs.some((i) => i.type === "password");
  const card = inputs.some((i) => /cc-number|cc-csc|cc-exp/.test(i.autocomplete || "") || /card.?number|cardnumber|cvv|cvc|security.?code/i.test((i.name || "") + " " + (i.id || "") + " " + (i.placeholder || "")));
  return { password, card, text: document.body ? document.body.innerText.slice(0, 30000) : "" };
})()`;

/**
 * Whether to pause before the person types on this page, in protected mode.
 * `knownSince` is when the person first visited the host (ISO), or null for never.
 */
function needsPause({ password, card }, knownSince, nowMs = Date.now()) {
  if (!password && !card) return null;
  const known = knownSince && nowMs - Date.parse(knownSince) > 24 * 3600_000;
  if (known) return null;
  return card ? "card" : "password";
}

/** Warning kinds a helper may be told about. Only the kind and the site's host name are ever sent. */
const ALERT_KINDS = ["lookalike", "reported", "scam-page", "remote-access", "pause", "download"];

module.exports = { REMOTE_ACCESS, SIGNALS, THRESHOLD, remoteAccessSite, scamPage, PAGE_PROBE, needsPause, ALERT_KINDS };
