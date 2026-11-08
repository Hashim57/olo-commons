"use strict";
(() => {
  const { el } = P;
  document.getElementById("app").append(
    el("h1", {}, "About POL Net"),
    el("p", { class: "lead" }, "POL Net is Helius Network's open-source browser and members' network. Proof of Life (POL) means one real person, one account."),
    el("div", { class: "card" }, el("h2", {}, "What it promises"),
      el("ul", {},
        el("li", {}, "No telemetry. POL Net never reports what you do. History, settings and permissions stay on this computer."),
        el("li", {}, "Shields on every page: trackers, surveillance ads, third-party cookies and tracking parameters removed; https everywhere; Global Privacy Control sent."),
        el("li", {}, "Warnings before harm: lookalike sites (fake banks, parcel and tax scams), sites verified members have reported, and downloads that can run programs."),
        el("li", {}, "A members' network (pol://) only verified people can open, where every site sees you under a different id."),
        el("li", {}, "Paid work, not attention: organisations fund tasks that help people and places, and members are paid for doing them, through Stripe."),
        el("li", {}, "Olo built in, with every answer checked by Zeus, and private by default."))),
    el("div", { class: "card" }, el("h2", {}, "Open source"), el("p", { class: "dim" }, "Browser, server and protocol: github.com/Hashim57/olo-commons, apps/polnet. Apache License 2.0. The design, threat model and economics are in docs/POLNET.md.")),
    el("div", { class: "card" }, el("h2", {}, "Honest limits"), el("p", { class: "dim" }, "POL Net is built on Chromium (through Electron). It is not yet an independent network: stage 1 runs pol:// sites on ordinary https servers listed in a members-only registry. The peer-to-peer stage is designed but not built. It has not yet had an external security audit.")),
  );
})();
