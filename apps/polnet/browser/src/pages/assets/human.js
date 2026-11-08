"use strict";
/* A site asks: "show me you are a real person". The member sees who is asking and what the site gets, and chooses. */
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const q = Object.fromEntries(new URLSearchParams(location.search));
  const check = await window.polnet.humanCheck(q);
  if (check.error) {
    app.append(el("h1", {}, "POL Net did not answer this request"), el("p", { class: "lead" }, check.error),
      el("button", { onclick: () => (history.length > 1 ? history.back() : (location.href = "polnet://newtab/")) }, "Go back"));
    return;
  }
  document.title = `${check.host} asks if you are a real person`;
  app.append(
    el("h1", {}, `${check.host} asks if you are a real person`),
    el("p", { class: "lead" }, "POL Net can answer for you without telling the site who you are."),
  );
  const area = el("div");
  app.append(area);
  if (!(await P.member(area))) return;
  const msg = el("p", { class: "small" });
  area.append(
    el("div", { class: "card" },
      el("strong", {}, `${check.host} will get`),
      el("ul", {},
        el("li", {}, "A yes: a verified person is here (checked once by Proof of Life when you joined)."),
        el("li", {}, `An id for you that only ${check.host} sees. Other sites get different ids, so they cannot compare notes.`)),
      el("strong", {}, "It will not get"),
      el("ul", {}, el("li", {}, "Your handle, name, email, phone number, location or anything about your other sites."))),
    el("div", { class: "row" },
      el("button", { class: "primary", onclick: async (e) => {
        e.target.disabled = true;
        msg.textContent = "Answering...";
        const r = await window.polnet.human(q);
        if (r.error) {
          msg.textContent = r.error;
          msg.className = "small error";
          e.target.disabled = false;
        }
      } }, `Yes, tell ${check.host}`),
      el("button", { onclick: () => history.back() }, "No thanks")),
    msg,
  );
})();
