"use strict";
/* The Square: the members' community, and HeliusTV (its "tv" topic). Everything is drawn as text nodes. */
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const NAMES = { ideas: "Ideas", projects: "Projects", questions: "Questions", research: "Research", impact: "Impact", tv: "HeliusTV" };
  const params = new URLSearchParams(location.search);
  let topic = params.get("topic") || "";
  let sort = "new";
  const tv = () => topic === "tv";

  const title = el("h1", {});
  const lead = el("p", { class: "lead" });
  const body = el("div");
  app.append(title, lead, body);
  const head = () => {
    document.title = tv() ? "HeliusTV" : "The Square";
    title.textContent = tv() ? "HeliusTV" : "The Square";
    lead.textContent = tv()
      ? "Videos from creators, innovators and people doing impact work, shared by members and ranked by one vote per real person. No adverts and no feed that plays by itself."
      : "Where members share what they are building, ask for help and show what worked. Everyone here is one verified person with one account and one vote, so nothing is pushed up by bots.";
  };
  head();

  const me = await P.member(body);
  if (!me) return;
  const cfg = await window.polnet.config();
  if (!cfg || !cfg.square) {
    body.replaceChildren(el("div", { class: "card" }, el("h2", {}, "Opening soon"), el("p", { class: "dim" }, "The Square is built and is waiting for its safety review before it opens to members. You do not need to do anything: it will appear here.")));
    return;
  }
  const topics = cfg.topics || Object.keys(NAMES);
  if (topic && !topics.includes(topic)) topic = "";

  const toast = el("div", { class: "notice", role: "status" });
  toast.hidden = true;
  const say = (text, bad) => { toast.hidden = false; toast.className = bad ? "notice error" : "notice"; toast.textContent = text; };
  const bar = el("div", { class: "row" });
  const list = el("div");
  const form = el("div");
  body.append(toast, bar, form, list);

  function drawBar() {
    const pick = (t, label) => el("button", { class: t === topic ? "primary" : "", onclick: () => { topic = t; head(); drawBar(); drawForm(); drawList(); } }, label);
    const order = el("select", { "aria-label": "Order", style: "width:150px" }, el("option", { value: "new" }, "Newest first"), el("option", { value: "top" }, "Most voted first"));
    order.value = sort;
    order.addEventListener("change", () => { sort = order.value; drawList(); });
    bar.replaceChildren(pick("", "Everything"), ...topics.map((t) => pick(t, NAMES[t] || t)), el("div", { class: "grow" }), order);
  }

  function drawForm() {
    const where = el("select", {}, ...topics.map((t) => el("option", { value: t }, NAMES[t] || t)));
    where.value = topic || "ideas";
    const heading = el("input", { maxlength: 140, placeholder: "A clear title" });
    const text = el("textarea", { rows: 4, maxlength: 6000 });
    const link = el("input", { maxlength: 2000 });
    const out = el("span", { class: "small" });
    const hint = () => {
      const isTv = where.value === "tv";
      text.placeholder = isTv ? "What the video is about and why it matters (optional)" : "What it is, what you learned, what you need. Say where numbers come from.";
      link.placeholder = isTv ? "https:// address of the video (needed)" : "https:// link (optional)";
    };
    where.addEventListener("change", hint);
    hint();
    form.replaceChildren(el("details", { class: "card" }, el("summary", {}, el("strong", {}, tv() ? "Share a video" : "Write a post")),
      el("label", {}, "Where"), where, el("label", {}, "Title"), heading, el("label", {}, "Text"), text, el("label", {}, "Link"), link,
      el("p", { class: "small dim" }, "Be kind and be specific. Posts are public to every member under your handle. Three members reporting a post take it down for review."),
      el("div", { class: "row" }, el("button", { class: "primary", onclick: async (e) => {
        e.target.disabled = true;
        const r = await P.api("POST", "/v1/square", { topic: where.value, title: heading.value, body: text.value, link: link.value });
        e.target.disabled = false;
        if (r.error) { out.className = "small error"; out.textContent = P.errorText(r); return; }
        heading.value = ""; text.value = ""; link.value = ""; out.textContent = "";
        say("Posted.");
        drawList();
      } }, "Post"), out)));
  }

  function hostOf(url) { try { return new URL(url).host; } catch { return ""; } }

  function card(p, full) {
    const count = el("span", {}, String(p.votes));
    const vote = el("button", { class: p.voted ? "primary" : "", "aria-pressed": p.voted ? "true" : "false", title: "One vote per person", onclick: async () => {
      const r = await P.api("POST", `/v1/square/${p.id}/vote`, { on: !p.voted });
      if (r.error) return say(P.errorText(r), true);
      p.voted = r.voted; p.votes = r.votes;
      count.textContent = String(p.votes);
      vote.className = p.voted ? "primary" : "";
      vote.setAttribute("aria-pressed", p.voted ? "true" : "false");
    } }, "▲ ", count);
    const open = (e) => { e.preventDefault(); show(p.id); };
    const c = el("div", { class: "card" },
      el("div", { class: "row" }, vote, el("div", { class: "grow" },
        full ? el("strong", {}, p.title) : el("a", { href: "#", onclick: open }, el("strong", {}, p.title)),
        el("div", { class: "small dim" }, el("span", { class: "tag" }, NAMES[p.topic] || p.topic), ` @${p.author} · ${P.when(p.created_at)} · ${p.comments} ${p.comments === 1 ? "comment" : "comments"}`))),
      p.body ? el("p", { style: "white-space:pre-wrap;overflow-wrap:anywhere" }, full || p.body.length <= 320 ? p.body : `${p.body.slice(0, 320)}...`) : null,
      p.link ? el("div", { class: "row" }, el("button", { class: p.topic === "tv" ? "earn" : "", onclick: () => window.polnet.open(p.link) }, p.topic === "tv" ? "Watch" : "Open link"), el("span", { class: "small dim" }, hostOf(p.link))) : null);
    const tools = el("div", { class: "row small", style: "margin-top:8px" });
    if (!full) tools.append(el("a", { href: "#", onclick: open }, "Read and reply"));
    if (p.mine) tools.append(el("a", { href: "#", onclick: async (e) => {
      e.preventDefault();
      if (!confirm("Delete this post and its comments?")) return;
      const r = await P.api("DELETE", `/v1/square/${p.id}`);
      if (r.error || !r.deleted) return say(P.errorText(r), true);
      say("Deleted."); drawBar(); drawForm(); drawList();
    } }, "Delete"));
    else {
      // Electron has no prompt(), so the reason is typed into the card itself.
      const why = el("input", { maxlength: 1000, placeholder: "What is wrong with it? (a scam, abuse, not what it says)" });
      const box = el("div", { class: "row", style: "margin-top:8px" }, el("div", { class: "grow" }, why), el("button", { onclick: async () => {
        const reason = why.value.trim();
        if (reason.length < 3) return why.focus();
        const r = await P.api("POST", "/v1/reports", { kind: "post", target: p.id, reason });
        say(r.error ? P.errorText(r) : r.action === "post_removed" ? "Reported. Three members have reported this post, so it has been taken down for review." : "Reported. Thank you.", Boolean(r.error));
        box.hidden = true;
        if (r.action === "post_removed") { drawBar(); drawForm(); drawList(); }
      } }, "Send report"));
      box.hidden = true;
      tools.append(el("a", { href: "#", onclick: (e) => { e.preventDefault(); box.hidden = !box.hidden; if (!box.hidden) why.focus(); } }, "Report"));
      c.append(tools, box);
      return c;
    }
    c.append(tools);
    return c;
  }

  async function drawList() {
    form.hidden = false; bar.hidden = false;
    const q = new URLSearchParams();
    if (topic) q.set("topic", topic);
    if (sort === "top") q.set("sort", "top");
    const r = await P.api("GET", `/v1/square${q.toString() ? `?${q}` : ""}`);
    if (r.error) return list.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
    if (!r.posts.length) return list.replaceChildren(el("div", { class: "card dim" }, tv() ? "No videos shared yet. Be the first." : "Nothing here yet. Be the first to post."));
    list.replaceChildren(...r.posts.map((p) => card(p, false)));
  }

  async function show(id) {
    const r = await P.api("GET", `/v1/square/${id}`);
    if (r.error) return say(P.errorText(r), true);
    form.hidden = true; bar.hidden = true; toast.hidden = true;
    const text = el("textarea", { rows: 3, maxlength: 3000, placeholder: "Add something useful" });
    const out = el("span", { class: "small" });
    const comments = el("div", {}, ...r.comments.map((c) => el("div", { class: "card" },
      el("div", { class: "small dim" }, `@${c.author} · ${P.when(c.created_at)}`), el("p", { style: "white-space:pre-wrap;overflow-wrap:anywhere" }, c.body),
      c.mine ? el("a", { href: "#", class: "small", onclick: async (e) => { e.preventDefault(); const d = await P.api("DELETE", `/v1/square/comments/${c.id}`); if (!d.error) show(id); } }, "Delete") : null)));
    list.replaceChildren(
      el("p", {}, el("a", { href: "#", onclick: (e) => { e.preventDefault(); drawList(); } }, "← Back")),
      card(r.post, true),
      el("p", { class: "small dim" }, "To check a claim in this post, select the words, right-click and choose \"Check this claim with Olo and Zeus\"."),
      el("h2", {}, r.comments.length === 1 ? "1 comment" : `${r.comments.length} comments`), comments,
      el("div", { class: "card" }, el("label", {}, "Your reply"), text, el("div", { class: "row", style: "margin-top:8px" }, el("button", { class: "primary", onclick: async () => {
        const c = await P.api("POST", `/v1/square/${id}/comments`, { body: text.value });
        if (c.error) { out.className = "small error"; out.textContent = P.errorText(c); return; }
        show(id);
      } }, "Reply"), out)));
    window.scrollTo(0, 0);
  }

  drawBar();
  drawForm();
  drawList();
})();
