"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const s = require("../../src/main/shields");

test("registrable domains", () => {
  assert.equal(s.siteOf("news.bbc.co.uk"), "bbc.co.uk");
  assert.equal(s.siteOf("a.b.example.com"), "example.com");
  assert.equal(s.siteOf("example.com"), "example.com");
  assert.equal(s.siteOf("192.168.1.4"), "192.168.1.4");
});

test("trackers are matched by host and parent domain, from the shipped list", () => {
  assert.ok(s.trackerList().size > 100);
  assert.ok(s.isTracker("www.google-analytics.com"));
  assert.ok(s.isTracker("stats.g.doubleclick.net"));
  assert.ok(s.isTracker("connect.facebook.net"));
  assert.ok(!s.isTracker("www.facebook.com"), "the site itself is not on the list, only its tracking hosts");
  assert.ok(!s.isTracker("bbc.co.uk"));
  assert.ok(!s.isTracker("notdoubleclick.net"));
});

test("tracking parameters are stripped, content parameters kept", () => {
  assert.equal(s.stripTrackingParams("https://shop.example/item?id=7&utm_source=x&utm_medium=y&fbclid=abc"), "https://shop.example/item?id=7");
  assert.equal(s.stripTrackingParams("https://www.youtube.com/watch?v=abc&si=track"), "https://www.youtube.com/watch?v=abc");
  assert.equal(s.stripTrackingParams("https://example.org/?si=keep"), null, "si only on YouTube and Spotify");
  assert.equal(s.stripTrackingParams("https://example.org/?q=hello"), null);
  assert.equal(s.stripTrackingParams("not a url"), null);
});

test("https upgrade leaves this computer and the local network alone", () => {
  assert.equal(s.httpsUpgrade("http://example.org/a"), "https://example.org/a");
  assert.equal(s.httpsUpgrade("http://example.org:80/a"), "https://example.org/a");
  assert.equal(s.httpsUpgrade("http://localhost:3000/"), null);
  assert.equal(s.httpsUpgrade("http://192.168.0.10/"), null);
  assert.equal(s.httpsUpgrade("http://printer.local/"), null);
  assert.equal(s.httpsUpgrade("http://example.org/", new Set(["example.org"])), null);
  assert.equal(s.httpsUpgrade("https://example.org/"), null);
});

test("decide: third-party trackers cancelled, first-party allowed, main-frame cleaned, shields off respected", () => {
  assert.deepEqual(s.decide({ url: "https://www.google-analytics.com/collect", resourceType: "script", topUrl: "https://news.example/" }), { cancel: true, reason: "tracker" });
  assert.deepEqual(s.decide({ url: "https://www.google-analytics.com/", resourceType: "mainFrame", topUrl: null }), {});
  assert.deepEqual(s.decide({ url: "https://www.google-analytics.com/collect", resourceType: "script", topUrl: "https://news.example/", shieldsOn: false }), {});
  assert.deepEqual(s.decide({ url: "http://news.example/a?utm_source=x", resourceType: "mainFrame" }), { redirectURL: "https://news.example/a", reason: "tracking-params" });
  assert.deepEqual(s.decide({ url: "http://news.example/a", resourceType: "image", topUrl: "https://news.example/" }), { redirectURL: "https://news.example/a", reason: "https" });
  assert.deepEqual(s.decide({ url: "polnet://newtab/", resourceType: "mainFrame" }), {});
});

test("third-party cookies are neither sent nor stored; privacy signals always sent", () => {
  assert.ok(s.isThirdParty("https://ads.other.example/x", "https://news.example/"));
  assert.ok(!s.isThirdParty("https://cdn.news.example/x", "https://www.news.example/"));
  const h = s.privacyHeaders({ Cookie: "a=1", "X-Client-Data": "abc", Accept: "*/*" }, { thirdParty: true });
  assert.equal(h.Cookie, undefined);
  assert.equal(h["X-Client-Data"], undefined);
  assert.equal(h["Sec-GPC"], "1");
  assert.equal(h.DNT, "1");
  assert.equal(s.privacyHeaders({ Cookie: "a=1" }, { thirdParty: false }).Cookie, "a=1");
  assert.equal(s.privacyHeaders({ Cookie: "a=1" }, { thirdParty: true, shieldsOn: false }).Cookie, "a=1");
  assert.deepEqual(s.stripThirdPartySetCookie({ "Set-Cookie": ["x"], "Content-Type": ["text/html"] }, { thirdParty: true }), { "Content-Type": ["text/html"] });
});
