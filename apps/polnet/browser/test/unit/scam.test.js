"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { scamPage, remoteAccessSite, needsPause, ALERT_KINDS } = require("../../src/main/scam");

test("a fake virus warning with a phone number is a scam page", () => {
  const r = scamPage("WARNING! Your computer has been infected with a Trojan. Do not close this window. Call Microsoft Support now on +1 (888) 555-0199 to unlock.");
  assert.ok(r);
  assert.ok(r.signals.includes("fake-virus"));
  assert.ok(r.signals.includes("call-support"));
  assert.ok(r.reasons.every((x) => typeof x === "string" && x.length > 10));
});

test("crypto doubling, safe accounts, seed phrases and gift-card fines are scam pages", () => {
  assert.ok(scamPage("Elon giveaway: send 0.1 BTC to the address below and we will send back double, 0.2 BTC, instantly!"));
  assert.ok(scamPage("Your bank account is at risk. Transfer your savings to a safe account today, within 24 hours, to protect them."));
  assert.ok(scamPage("Wallet sync error. Please enter your 12-word recovery phrase to restore access immediately."));
  assert.ok(scamPage("HMRC final notice: pay the outstanding tax fine using Google Play cards. Account will be suspended within 24 hours."));
});

test("ordinary pages that mention the same words are not flagged", () => {
  const ordinary = [
    "How to remove a virus from your computer: run your antivirus, keep Windows updated, and never call numbers shown in pop-ups.",
    "Gift cards make great presents. Buy an Amazon gift card for a friend's birthday.",
    "Bitcoin price today: BTC rose 3% as markets opened. Analysts expect volatility.",
    "Contact our support team by email. We usually reply within 24 hours.",
    "Congratulations to the winners of the school science fair!",
    "",
  ];
  for (const t of ordinary) assert.equal(scamPage(t), null, t);
});

test("remote-control tools are recognised, including a path-scoped entry", () => {
  assert.equal(remoteAccessSite("anydesk.com"), "anydesk.com");
  assert.equal(remoteAccessSite("download.teamviewer.com"), "teamviewer.com");
  assert.equal(remoteAccessSite("www.zoho.com", "/assist/join"), "zoho.com");
  assert.equal(remoteAccessSite("www.zoho.com", "/mail"), null);
  assert.equal(remoteAccessSite("example.org"), null);
  assert.equal(remoteAccessSite("notanydesk.com"), null);
});

test("the pause comes before passwords and cards on new sites only", () => {
  const now = Date.parse("2026-11-08T12:00:00Z");
  assert.equal(needsPause({ password: true, card: false }, null, now), "password");
  assert.equal(needsPause({ password: true, card: true }, null, now), "card");
  assert.equal(needsPause({ password: false, card: true }, "2026-11-08T11:00:00Z", now), "card", "first seen an hour ago is still new");
  assert.equal(needsPause({ password: true, card: false }, "2026-10-01T09:00:00Z", now), null, "a site used for weeks is known");
  assert.equal(needsPause({ password: false, card: false }, null, now), null);
});

test("alert kinds are a fixed list", () => {
  assert.deepEqual(ALERT_KINDS, ["lookalike", "reported", "scam-page", "remote-access", "pause", "download"]);
});
