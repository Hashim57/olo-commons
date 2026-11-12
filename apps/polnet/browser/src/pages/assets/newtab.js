"use strict";
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const s = await window.polnet.status();
  const go = (url) => () => { location.href = url; };
  app.append(
    el("h1", {}, s && s.member ? `Welcome back, @${s.member.handle}` : "POL Net"),
    el("p", { class: "lead" }, "The browser that keeps you private, warns you before harm, connects real people, and pays you for work that makes things better."),
    el("div", { class: "grid" },
      el("div", { class: "card" }, el("h2", {}, "Earn"), el("p", { class: "dim small" }, "Organisations pay members for real work: local data, translation, fact checks, accessibility audits, environmental reports. Paid in pounds or euros."), el("button", { class: "earn", onclick: go("polnet://tasks/") }, "See tasks that pay")),
      el("div", { class: "card" }, el("h2", {}, "The Square"), el("p", { class: "dim small" }, "The members' community for innovation and impact: ideas, projects, questions and research from real people, one vote each. HeliusTV is here too."), el("div", { class: "row" }, el("button", { onclick: go("polnet://square/") }, "Open the Square"), el("button", { onclick: go("polnet://square/?topic=tv") }, "HeliusTV"))),
      el("div", { class: "card" }, el("h2", {}, "Teach Zeus"), el("p", { class: "dim small" }, "Check a claim against its sources. When three real people agree, it becomes a lesson for Zeus, the open verifier behind Olo."), el("button", { onclick: go("polnet://teach/") }, "Check a claim")),
      el("div", { class: "card" }, el("h2", {}, "Ask Olo"), el("p", { class: "dim small" }, "Questions answered from sources you can open, every sentence checked by Zeus. Private: nothing is kept. Use the Ask Olo button in the toolbar."), el("span", { class: "tag" }, "Cmd+Shift+O")),
      el("div", { class: "card" }, el("h2", {}, "Members' network"), el("p", { class: "dim small" }, "pol:// sites are only for verified people: no bots, no fake accounts. Each site sees you under a different id, so sites cannot follow you between them."), el("button", { onclick: go("polnet://names/") }, "pol:// names")),
      el("div", { class: "card" }, el("h2", {}, "Safe from scams"), el("p", { class: "dim small" }, "Warnings before fake sites, scam pages and remote-control tricks. Protected mode adds a pause before passwords and cards on new sites, and Family help lets someone you trust know when POL Net had to warn."), el("button", { onclick: go("polnet://family/") }, "Family help")),
      el("div", { class: "card" }, el("h2", {}, "Private by default"), el("p", { class: "dim small" }, "Trackers blocked, third-party cookies refused, tracking parameters stripped, https everywhere, no telemetry. Your history never leaves this computer."), el("button", { onclick: go("polnet://settings/") }, "Privacy settings")),
      el("div", { class: "card" }, el("h2", {}, "Free, and what is paid"), el("p", { class: "dim small" }, "The browser, the members' network, the Square, Olo's daily messages and the open knowledge base are free. A few services are paid, and they pay for the rest: no adverts, no tracking, no data for sale."), el("button", { onclick: go("polnet://services/") }, "See every service")),
    ),
  );
})();
