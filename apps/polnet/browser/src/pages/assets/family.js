"use strict";
/* Family help and protected mode: stronger scam protection for someone, and a word to the people who help them. */
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const s = await window.polnet.settings();

  const box = el("input", { type: "checkbox" });
  box.checked = Boolean(s.protectedMode);
  const state = el("span", { class: "small dim" });
  box.addEventListener("change", async () => {
    await window.polnet.settings({ protectedMode: box.checked });
    state.textContent = box.checked ? "Protected mode is on." : "Protected mode is off.";
  });

  app.append(
    el("h1", {}, "Family help"),
    el("p", { class: "lead" }, "Stronger scam protection for someone you care about, or for yourself, and a quiet word to the people who help when POL Net has to warn."),
    el("div", { class: "card" },
      el("label", { class: "toggle" }, box, el("span", {}, el("strong", {}, "Protected mode"), el("br"),
        el("span", { class: "dim small" }, "Pauses before a password or card number is typed on a site used for the first time. Warns before remote-control software that scammers ask people to install. Does not download files that can run programs. Waits a few seconds before \"open anyway\" on every warning. Everything is checked on this computer."))),
      state),
  );

  const area = el("div");
  app.append(area);
  if (!(await P.member(area))) return;

  const helpersCard = el("div", { class: "card" });
  const helpingCard = el("div", { class: "card" });
  const alertsCard = el("div", { class: "card" });
  area.append(
    el("h2", {}, "People who help me"),
    el("p", { class: "dim small" }, "When POL Net warns you in protected mode, your helpers see the site's name and the kind of warning, so they can call you. They never see your history, what you read or what you typed. Up to three helpers; you can remove one at any time. Private windows send nothing."),
    helpersCard,
    el("h2", {}, "People I help"),
    helpingCard,
    el("h2", {}, "Warnings for the people I help"),
    alertsCard,
  );

  const WORDS = { lookalike: "opened a fake-looking site", reported: "opened a site members reported", "scam-page": "saw a page that looks like a scam", "remote-access": "opened remote-control software", pause: "was about to type a password or card on a new site", download: "tried to download a program" };

  async function load() {
    const r = await P.api("GET", "/v1/helpers");
    if (r.error) {
      helpersCard.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
      return;
    }
    const end = async (id, who) => {
      if (!confirm(`End the link with ${who}?`)) return;
      await P.api("DELETE", `/v1/helpers/${id}`);
      load();
    };
    const code = el("div");
    helpersCard.replaceChildren(
      ...(r.helpers.length ? r.helpers.map((h) => el("div", { class: "row" }, el("span", { class: "grow" }, `@${h.handle}`, el("span", { class: "dim small" }, ` since ${P.when(h.since)}`)), el("button", { onclick: () => end(h.id, `@${h.handle}`) }, "Remove"))) : [el("p", { class: "dim" }, "No helpers yet.")]),
      el("div", { class: "row", style: "margin-top:10px" }, el("button", { class: "primary", onclick: async () => {
        const inv = await P.api("POST", "/v1/helpers/invite");
        code.replaceChildren(inv.error
          ? el("p", { class: "error" }, P.errorText(inv))
          : el("div", { class: "notice" }, "Give this code to the person who will help you, in person or by phone. It works once, for 24 hours: ", el("strong", { style: "font-size:20px;letter-spacing:2px" }, inv.code)));
      } }, "Add a helper")),
      code,
    );
    const input = el("input", { placeholder: "e.g. K7QM-9TXA", maxlength: "12", autocomplete: "off" });
    const msg = el("p", { class: "small" });
    helpingCard.replaceChildren(
      ...(r.helping.length ? r.helping.map((h) => el("div", { class: "row" }, el("span", { class: "grow" }, `@${h.handle}`, el("span", { class: "dim small" }, ` since ${P.when(h.since)}`)), el("button", { onclick: () => end(h.id, `@${h.handle}`) }, "Stop helping"))) : [el("p", { class: "dim" }, "You do not help anyone yet.")]),
      el("label", {}, "Someone gave me a code"),
      el("div", { class: "row" }, el("div", { class: "grow" }, input), el("button", { onclick: async () => {
        const a = await P.api("POST", "/v1/helpers/accept", { code: input.value });
        msg.textContent = a.error ? P.errorText(a) : `You now help @${a.helping}. You will see here when POL Net warns them.`;
        msg.className = a.error ? "small error" : "small";
        if (!a.error) load();
      } }, "Help them")),
      msg,
    );
    const al = await P.api("GET", "/v1/helpers/alerts");
    const rows = al.alerts || [];
    alertsCard.replaceChildren(rows.length
      ? el("table", {}, ...rows.map((a) => el("tr", {}, el("td", {}, P.when(a.at)), el("td", {}, `@${a.handle} ${WORDS[a.kind] || a.kind}`), el("td", { class: "dim" }, a.host))))
      : el("p", { class: "dim" }, "No warnings in the last 30 days."));
  }
  load();
})();
