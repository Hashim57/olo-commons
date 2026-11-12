"use strict";
/* Teach Zeus: a member checks one claim against its passages. Three members who agree make one lesson
   for Zeus, the open verifier behind Olo. Everything is drawn as text nodes. */
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const pulse = el("p", { class: "small dim" });
  const body = el("div");
  app.append(
    el("h1", {}, "Teach Zeus"),
    el("p", { class: "lead" }, "Zeus is the open verifier that checks every sentence Olo writes. It learns from examples, and the best examples come from careful people. Read a claim, read the passages, and say what the passages show. When three real people agree, it becomes a lesson."),
    pulse, body);

  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  async function drawPulse() {
    const s = await P.api("GET", "/v1/checks/stats");
    if (!s || s.error) return;
    pulse.textContent = `So far: ${plural(s.labels, "check", "checks")} from ${plural(s.people, "person", "people")}, ${plural(s.agreed, "lesson", "lessons")} agreed, ${s.open} waiting.`;
  }
  drawPulse();

  const me = await P.member(body);
  if (!me) return;

  const WORDS = { supported: "The passages support it", contradicted: "The passages contradict it", not_covered: "The passages do not say" };

  async function next(note) {
    const r = await P.api("GET", "/v1/checks/next");
    if (!r || r.error) return body.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
    const mine = el("p", { class: "small dim" }, r.mine.labels ? `You have checked ${plural(r.mine.labels, "claim", "claims")}. ${plural(r.mine.agreed_with, "answer", "answers")} of yours matched what others found.` : "Your first check. Take your time: careful beats fast.");
    const said = note ? el("div", { class: "notice", role: "status" }, note) : null;
    if (!r.item) {
      return body.replaceChildren(...[said, el("div", { class: "card" }, el("h2", {}, "Nothing to check just now"), el("p", { class: "dim" }, "You have checked everything that is waiting. New claims are added as the Commons grows.")), mine].filter(Boolean));
    }
    const item = r.item;
    let chosen = null; // { passage, quote }
    const picked = el("p", { class: "small", id: "picked" }, "No words selected yet.");
    const out = el("span", { class: "small error" });

    const passages = item.passages.map((p) => {
      const text = el("p", { "data-passage": p.id, style: "white-space:pre-wrap;overflow-wrap:anywhere;user-select:text" }, p.text);
      return el("div", { class: "card" }, text,
        el("div", { class: "row small dim" }, el("span", { class: "tag" }, p.source), el("a", { href: "#", onclick: (e) => { e.preventDefault(); window.polnet.open(p.url); } }, "Open the source")));
    });

    // The quote is whatever the member selects inside one passage, exactly as written.
    const read = () => {
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed || !sel.rangeCount) return;
      const inside = (n) => { const e = n && (n.nodeType === 1 ? n : n.parentElement); return e ? e.closest("[data-passage]") : null; };
      const a = inside(sel.anchorNode), b = inside(sel.focusNode);
      if (!a || a !== b) return;
      const quote = sel.toString().trim();
      const full = a.textContent;
      if (quote.length < 8 || quote.length > 600 || !full.includes(quote)) return;
      chosen = { passage: a.getAttribute("data-passage"), quote };
      picked.textContent = `Selected: "${quote}"`;
      out.textContent = "";
    };
    document.onselectionchange = read;

    const send = async (label, e) => {
      if (label !== "not_covered" && !chosen) { out.textContent = "First select the words in one passage that decide it."; return; }
      e.target.disabled = true;
      const sent = await P.api("POST", `/v1/checks/${item.id}/label`, label === "not_covered" ? { label } : { label, passage: chosen.passage, quote: chosen.quote });
      e.target.disabled = false;
      if (sent.error && sent.error !== "check_closed") { out.textContent = P.errorText(sent); return; }
      drawPulse();
      next(sent.error ? "That one was settled while you were reading. Here is another." : sent.settled ? (sent.agreed ? "Recorded. Enough people agreed with you, so this one is now a lesson for Zeus." : "Recorded. People did not agree on this one, so it is set aside.") : "Recorded. Thank you.");
    };

    body.replaceChildren(...[said,
      el("div", { class: "card" }, el("div", { class: "small dim" }, "The claim"), el("h2", { id: "claim" }, item.claim)),
      el("h2", {}, "What the sources say"), ...passages,
      el("div", { class: "card" },
        el("p", { class: "small dim" }, "If the passages settle it, select the exact words that do (drag across them in one passage), then choose. If they do not say either way, choose the last button: that is a real answer, not a failure."),
        picked,
        el("div", { class: "row" },
          el("button", { class: "primary", "data-label": "supported", onclick: (e) => send("supported", e) }, WORDS.supported),
          el("button", { "data-label": "contradicted", onclick: (e) => send("contradicted", e) }, WORDS.contradicted),
          el("button", { "data-label": "not_covered", onclick: (e) => send("not_covered", e) }, WORDS.not_covered)),
        out),
      mine].filter(Boolean));
    window.scrollTo(0, 0);
  }
  next();
})();
