"use strict";
/**
 * POL Net online safety: warnings before harm, never silent blocking of ordinary sites.
 *
 *  - Lookalike sites: a host that borrows a brand people are commonly phished with (a bank, a parcel
 *    company, HMRC, a crypto wallet) without being that brand's real domain, written with digits for
 *    letters, an extra word ("paypal-secure-login"), one letter off ("gooogle"), or in punycode.
 *  - The community list: sites reported by three or more members, checked by hash prefix
 *    (lookupHashPrefix), so the server never learns which site the person is visiting.
 *  - Downloads that can run code are confirmed first.
 * Pure functions; the main process shows the warning page.
 */

const { siteOf } = require("./shields");
const crypto = require("node:crypto");

/** Brands phished most in the UK and EU, with the domains that really are theirs. */
const BRANDS = {
  paypal: ["paypal.com", "paypal.me", "paypal.co.uk"],
  apple: ["apple.com", "icloud.com", "apple.co"],
  google: ["google.com", "google.co.uk", "gmail.com", "youtube.com", "goo.gl", "googleusercontent.com", "gstatic.com", "googleapis.com"],
  microsoft: ["microsoft.com", "live.com", "outlook.com", "office.com", "microsoftonline.com", "office365.com", "xbox.com", "bing.com", "msn.com"],
  amazon: ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.es", "amazon.it", "amazon.nl", "amazonaws.com", "primevideo.com"],
  facebook: ["facebook.com", "fb.com", "fbcdn.net", "messenger.com"],
  instagram: ["instagram.com", "cdninstagram.com"],
  whatsapp: ["whatsapp.com", "whatsapp.net"],
  netflix: ["netflix.com", "nflxext.com", "nflximg.net"],
  hmrc: ["gov.uk"],
  dvla: ["gov.uk"],
  nhs: ["nhs.uk"],
  royalmail: ["royalmail.com", "royalmailgroup.com"],
  evri: ["evri.com"],
  dpd: ["dpd.co.uk", "dpd.com", "dpdlocal.co.uk"],
  dhl: ["dhl.com", "dhl.co.uk", "dhl.de"],
  barclays: ["barclays.co.uk", "barclays.com", "barclaycard.co.uk"],
  hsbc: ["hsbc.co.uk", "hsbc.com"],
  lloyds: ["lloydsbank.com", "lloydsbank.co.uk", "lloydsbankinggroup.com"],
  natwest: ["natwest.com"],
  santander: ["santander.co.uk", "santander.com"],
  halifax: ["halifax.co.uk"],
  nationwide: ["nationwide.co.uk"],
  monzo: ["monzo.com"],
  revolut: ["revolut.com"],
  starling: ["starlingbank.com"],
  coinbase: ["coinbase.com"],
  binance: ["binance.com"],
  metamask: ["metamask.io"],
  phantom: ["phantom.app"],
  steam: ["steampowered.com", "steamcommunity.com"],
  docusign: ["docusign.com", "docusign.net"],
  ebay: ["ebay.com", "ebay.co.uk"],
  heliusnetwork: ["heliusnetwork.app", "helius-olo.io", "heliusnetwork.com"],
};

/** Characters swapped in for letters to fool a reader. */
const CONFUSABLE = { 0: "o", 1: "l", 3: "e", 4: "a", 5: "s", 7: "t", 8: "b", "@": "a", "$": "s", "|": "l", "!": "i", vv: "w", rn: "m" };

function deconfuse(s) {
  let t = String(s).toLowerCase();
  t = t.replace(/vv/g, "w").replace(/rn/g, "m");
  return t.replace(/[0-9@$|!]/g, (c) => CONFUSABLE[c] ?? c);
}

/** Levenshtein distance, stopping early above `max`. */
function distance(a, b, max = 2) {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let cur = [i];
    let rowMin = i;
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      rowMin = Math.min(rowMin, cur[j]);
    }
    if (rowMin > max) return max + 1;
    for (let j = 0; j <= b.length; j++) prev[j] = cur[j];
  }
  return prev[b.length];
}

function isOfficial(host, domains) {
  const h = String(host).toLowerCase();
  return domains.some((d) => h === d || h.endsWith(`.${d}`));
}

/** Words phishing pages put next to a brand. */
const BAIT = new Set(["login", "log", "signin", "sign", "secure", "security", "verify", "verification", "account", "accounts", "support", "help", "update",
  "billing", "pay", "payment", "payments", "refund", "refunds", "wallet", "auth", "service", "services", "online", "bank", "banking", "alert", "alerts",
  "track", "tracking", "delivery", "parcel", "customs", "tax", "rebate", "claim", "unlock", "recovery", "restore", "confirm", "id", "check", "official", "web", "app"]);

/**
 * Whether a host looks like a brand it is not.
 * @returns {{brand: string, official: string, why: "punycode"|"digits"|"subdomain"|"bait-words"|"one-letter-off"} | null}
 */
function lookalike(host) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  if (!h || /^\d+\.\d+\.\d+\.\d+$/.test(h)) return null;
  for (const domains of Object.values(BRANDS)) if (isOfficial(h, domains)) return null;
  const site = siteOf(h);
  const siteLabel = site.split(".")[0];
  const sub = h.slice(0, Math.max(0, h.length - site.length - 1));
  const subWords = sub ? sub.split(/[.\-_]+/).filter(Boolean) : [];
  const siteWords = siteLabel.split(/[\-_]+/).filter(Boolean);
  const punycode = h.split(".").some((l) => l.startsWith("xn--"));
  for (const [brand, domains] of Object.entries(BRANDS)) {
    const official = domains[0];
    // The brand as a subdomain of someone else's site: paypal.com.account-check.net, hmrc.refund-claim.uk.
    if (subWords.some((w) => w === brand || deconfuse(w) === brand)) return { brand, official, why: "subdomain" };
    for (const w of siteWords) {
      const plain = deconfuse(w);
      // Digits or doubled letters for letters: paypa1, rnicrosoft, g00gle.
      if (w !== brand && plain === brand) return { brand, official, why: "digits" };
      // One letter off a longer brand: gooogle, amazom, barclay5 is caught above.
      if (brand.length >= 5 && w.length >= 5 && w !== brand && distance(w, brand, 1) === 1) return { brand, official, why: "one-letter-off" };
      // The brand with bait words: paypal-secure-login, hmrc-tax-refund, myroyalmail-parcel.
      const others = siteWords.filter((x) => x !== w);
      if ((w === brand || plain === brand) && others.some((x) => BAIT.has(x))) return { brand, official, why: "bait-words" };
      if (w !== brand && brand.length >= 4 && plain.includes(brand)) {
        const rest = plain.replace(brand, " ").split(" ").filter(Boolean);
        if (rest.length && rest.every((r) => BAIT.has(r) || r === "my" || r === "the")) return { brand, official, why: "bait-words" };
      }
      // The bare brand on a domain it does not own, in another script or punycode.
      if (punycode && plain.includes(brand.slice(0, 4))) return { brand, official, why: "punycode" };
    }
    if (siteWords.length === 1 && siteWords[0] === brand && !site.endsWith(".com") && brand.length >= 4) {
      // paypal.help, apple.support: the brand on a registry it does not use.
      return { brand, official, why: "bait-words" };
    }
  }
  return null;
}

/** The first 8 hex of the SHA-256 of a host name: what the browser sends to the community safety list. */
function hostHash(host) {
  return crypto.createHash("sha256").update(String(host).toLowerCase()).digest("hex");
}

/** File types that can run code or install software. */
const RISKY = new Set(["exe", "msi", "scr", "bat", "cmd", "com", "pif", "vbs", "vbe", "js", "jse", "wsf", "wsh", "ps1", "jar", "apk", "dmg", "pkg", "app", "command", "sh", "iso", "img", "reg", "hta", "lnk", "dll", "msix", "appx", "deb", "rpm"]);

function riskyDownload(filename) {
  const m = /\.([a-z0-9]+)$/i.exec(String(filename || ""));
  return m ? RISKY.has(m[1].toLowerCase()) : false;
}

module.exports = { BRANDS, BAIT, lookalike, deconfuse, distance, hostHash, riskyDownload };
