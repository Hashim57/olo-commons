"use strict";
/* Helpers shared by the browser's own pages. They reach the main process only through window.polnet. */
window.P = {
  $: (sel) => document.querySelector(sel),
  el(tag, attrs = {}, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === "class") e.className = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    return e;
  },
  money(pence, currency = "GBP") {
    return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format((pence || 0) / 100);
  },
  when(iso) {
    if (!iso) return "";
    return new Date(iso).toLocaleString("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
  },
  async api(method, path, body) {
    return window.polnet.api(method, path, body);
  },
  /** Shows "join first" in `box` and returns false when the person is not a member. */
  async member(box) {
    const s = await window.polnet.status();
    if (s && s.member) return s.member;
    box.replaceChildren(P.el("div", { class: "card" },
      P.el("h2", {}, "Join POL Net first"),
      P.el("p", { class: "dim" }, "One quick check that you are a real person (Proof-of-Life, on your phone), then choose a handle. No email, no name and no phone number are kept. One person, one account: that is what keeps the members' network free of bots and fake reviews, and it is why organisations trust the work members do."),
      P.el("button", { class: "primary", onclick: () => window.polnet.join() }, "Join POL Net")));
    return null;
  },
  errorText(r) {
    return (r && (r.message || r.error)) || "Something went wrong.";
  },
};
