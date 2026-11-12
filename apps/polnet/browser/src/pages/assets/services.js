"use strict";
/* Free and paid services: one honest list, read from the public catalogue (GET /v1/services). */
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  app.append(
    el("h1", {}, "Free, and what is paid"),
    el("p", { class: "lead" }, "Most of what Helius makes is free: the browser, the members' network, the Square, Olo's daily messages and the open knowledge base. A few services are paid. They pay for the free ones, so nothing here is paid for with adverts, tracking or your data."));
  const body = el("div");
  app.append(body);
  const r = await P.api("GET", "/v1/services");
  if (!r || r.error || !Array.isArray(r.services)) {
    body.append(el("p", { class: "error" }, P.errorText(r)));
    return;
  }
  const STATUS = { live: null, soon: "Opening soon", planned: "Planned, not on sale yet" };
  const internal = { square: "polnet://square/", heliustv: "polnet://square/?topic=tv", teach: "polnet://teach/", tasks: "polnet://tasks/", "task-posting": "polnet://tasks/", members: "polnet://names/", family: "polnet://family/" };
  const counts = { free: r.services.filter((s) => s.kind === "free").length, paid: r.services.filter((s) => s.kind === "paid" && s.status !== "planned").length, planned: r.services.filter((s) => s.status === "planned").length };
  body.append(el("div", { class: "row" },
    el("span", { class: "tag" }, `${counts.free} free`), el("span", { class: "tag" }, `${counts.paid} paid`), el("span", { class: "tag" }, `${counts.planned} planned`)));

  for (const [key, label] of Object.entries(r.groups || {})) {
    const items = r.services.filter((s) => s.group === key);
    if (!items.length) continue;
    // Free first in every group.
    items.sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "free" ? -1 : 1));
    body.append(el("h2", {}, label), el("div", { class: "grid" }, ...items.map((s) => {
      const to = s.status === "planned" ? null : internal[s.key] || s.url;
      return el("div", { class: "card" },
        el("div", { class: "row" }, el("strong", { class: "grow" }, s.name), el("span", { class: s.kind === "free" ? "money" : "tag" }, s.kind === "free" ? "Free" : "Paid")),
        el("p", { class: "small" }, s.summary),
        el("p", { class: "small dim" }, s.price),
        STATUS[s.status] ? el("div", { class: "small dim" }, el("span", { class: "tag" }, STATUS[s.status])) : null,
        to ? el("div", { style: "margin-top:10px" }, el("button", { class: s.kind === "paid" ? "primary" : "", onclick: () => { if (to.startsWith("polnet://")) location.href = to; else window.polnet.open(to); } }, s.kind === "paid" ? "See it" : "Open")) : null);
    })));
  }
  body.append(el("p", { class: "small dim", style: "margin-top:28px" }, "Planned services are listed so you know what is coming. They have no price and cannot be bought until they are built and checked."));
})();
