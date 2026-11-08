"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { lookalike, riskyDownload, hostHash, deconfuse, distance } = require("../../src/main/safety");

test("real brand sites are never flagged", () => {
  for (const h of ["paypal.com", "www.paypal.com", "barclays.co.uk", "online.barclays.co.uk", "www.gov.uk", "hmrc.gov.uk", "docs.google.com", "google.co.uk", "monzo.com", "www.amazon.co.uk", "login.microsoftonline.com", "nhs.uk", "www.royalmail.com"]) {
    assert.equal(lookalike(h), null, h);
  }
});

test("ordinary sites that share a word with a brand are not flagged", () => {
  for (const h of ["applebees.com", "apple-music-fans.com", "amazonia.org", "bbc.co.uk", "github.com", "example.org", "googleplex-tours.example"]) {
    assert.equal(lookalike(h), null, h);
  }
});

test("lookalikes are flagged with the reason", () => {
  const cases = {
    "paypa1.com": "digits",
    "rnicrosoft.com": "digits",
    "gooogle.com": "one-letter-off",
    "paypal-secure-login.com": "bait-words",
    "hmrc-tax-refund.co.uk": "bait-words",
    "royalmail-parcel-redelivery.com": "bait-words",
    "myroyalmail.com": "bait-words",
    "monzologin.com": "bait-words",
    "metamask-wallet.io": "bait-words",
    "paypal.com.account-check.net": "subdomain",
    "paypal.help": "bait-words",
  };
  for (const [host, why] of Object.entries(cases)) {
    const r = lookalike(host);
    assert.ok(r, `${host} should be flagged`);
    assert.equal(r.why, why, host);
  }
  assert.equal(lookalike("hmrc-tax-refund.co.uk").official, "gov.uk");
});

test("helpers", () => {
  assert.equal(deconfuse("paypa1"), "paypal");
  assert.equal(distance("gooogle", "google"), 1);
  assert.equal(hostHash("Example.ORG"), hostHash("example.org"));
  assert.equal(hostHash("example.org").length, 64);
  assert.ok(riskyDownload("invoice.pdf.exe"));
  assert.ok(riskyDownload("Installer.DMG"));
  assert.ok(!riskyDownload("report.pdf"));
  assert.ok(!riskyDownload("photo.jpg"));
});
