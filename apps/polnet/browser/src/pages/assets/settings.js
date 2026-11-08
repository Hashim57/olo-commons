"use strict";
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const s = await window.polnet.settings();
  const status = await window.polnet.status();
  const save = async (patch) => { await window.polnet.settings(patch); saved.textContent = "Saved."; setTimeout(() => { saved.textContent = ""; }, 1500); };
  const saved = el("span", { class: "small dim" });
  const toggle = (key, label, help) => {
    const box = el("input", { type: "checkbox" });
    box.checked = s[key] !== false;
    box.addEventListener("change", () => save({ [key]: box.checked }));
    return el("label", { class: "toggle" }, box, el("span", {}, el("strong", {}, label), el("br"), el("span", { class: "dim small" }, help)));
  };
  const engine = el("select", {}, ...Object.entries(status.engines).map(([k, v]) => el("option", { value: k }, v.name)));
  engine.value = s.search;
  engine.addEventListener("change", () => save({ search: engine.value }));
  const server = el("input", { value: s.server });
  const oloBase = el("input", { value: s.olo });
  app.append(
    el("h1", {}, "Settings"), saved,
    el("h2", {}, "Privacy"),
    el("div", { class: "card" },
      toggle("shields", "Shields", "Block trackers and surveillance ads, refuse third-party cookies, strip tracking parameters, send Global Privacy Control. You can turn Shields off for one site from the toolbar."),
      toggle("httpsOnly", "https everywhere", "Upgrade every plain http address to https, and say so before opening a site that has no secure version."),
      toggle("history", "Keep history on this computer", "Nothing is ever sent anywhere. Private windows never keep history."),
      el("label", {}, "Search engine"), engine,
      el("div", { class: "row", style: "margin-top:14px" }, el("button", { onclick: async () => { if (confirm("Delete history, cookies, site data and the cache on this computer?")) { await window.polnet.clearData(); saved.textContent = "Cleared."; } } }, "Clear browsing data"))),
    el("h2", {}, "Safety"),
    el("div", { class: "card" },
      toggle("safetyList", "Warn me about sites members have reported", "Checked without revealing the site: only 8 characters of a hash of the site's name are sent, shared by thousands of other sites."),
      el("p", { class: "dim small" }, "Lookalike warnings (fake banks, parcel and tax scams) and download warnings are always on.")),
    el("h2", {}, "Olo"),
    el("div", { class: "card" },
      toggle("oloPrivate", "Private questions", "helius-olo.io does not store your questions to Olo from POL Net, train on them, or add them to the Olo brain."),
      toggle("oloIncludePage", "Offer to include the page", "Ask Olo can read the visible text of the page you are on, only when you leave \"Include this page\" ticked.")),
    el("h2", {}, "Servers"),
    el("div", { class: "card" },
      el("label", {}, "POL Net server"), server, el("label", {}, "Olo"), oloBase,
      el("div", { class: "row", style: "margin-top:10px" }, el("button", { onclick: () => save({ server: server.value.trim(), olo: oloBase.value.trim() }) }, "Save servers")),
      el("p", { class: "dim small" }, "POL Net is open source: anyone can run a server. Changing it signs you out of the old one.")),
  );
})();
