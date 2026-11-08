"use strict";
/* The toolbar, tabs and the Olo panel. Talks to the main process only through window.browser. */
(() => {
  const $ = (id) => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  if (params.get("private") === "1") document.body.classList.add("private");
  if (params.get("platform") === "darwin") document.body.classList.add("darwin");
  $("private-badge").hidden = params.get("private") !== "1";

  let state = null;
  let editing = false;

  function el(tag, attrs = {}, text) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") e.className = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    }
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function render(s) {
    state = s;
    const tabs = $("tabs");
    tabs.replaceChildren(...s.tabs.map((t) => {
      const node = el("div", { class: `tab${s.active && t.id === s.active.id ? " on" : ""}`, role: "tab", title: t.title, "data-id": String(t.id), onmousedown: (e) => { if (e.button === 1) { e.preventDefault(); window.browser.closeTab(t.id); } else window.browser.activate(t.id); } });
      if (t.favicon && !t.loading) node.append(el("img", { src: t.favicon, alt: "" }));
      else node.append(el("span", { class: `dot${t.loading ? " loading" : ""}` }));
      node.append(el("span", { class: "title" }, t.title || "New tab"));
      node.append(el("button", { class: "x", title: "Close tab", "aria-label": "Close tab", onmousedown: (e) => { e.stopPropagation(); window.browser.closeTab(t.id); } }, "×"));
      return node;
    }));
    const a = s.active;
    $("back").disabled = !a?.canBack;
    $("forward").disabled = !a?.canForward;
    if (!editing) $("address").value = a?.url || "";
    $("address").placeholder = `Search privately with ${s.engine} or type an address`;
    const lock = $("lock");
    lock.className = !a?.url ? "" : a.member ? "member" : a.secure ? "secure" : "insecure";
    lock.title = !a?.url ? "" : a.member ? "Members' network: pol://" : a.secure ? "Encrypted connection" : "Not encrypted: anyone on the network can read this";
    $("shield-count").textContent = a?.shields === false ? "off" : String(a?.blocked || 0);
    $("shield").classList.toggle("off", a?.shields === false);
    $("shield").disabled = !a?.host;
    $("shield").title = a?.host ? `Shields ${a.shields === false ? "off" : "on"} for ${a.host}: ${a.blocked || 0} trackers blocked on this page` : "Shields";
    const m = $("member");
    m.textContent = s.member ? `@${s.member.handle}` : "Join";
    m.classList.toggle("member", Boolean(s.member));
    m.title = s.member ? "Your POL Net membership: one verified person, one account" : "Join POL Net: one check that you are a real person";
    $("signout").hidden = !s.member;
    $("panel").hidden = !s.panel;
    $("olo").classList.toggle("member", s.panel);
  }

  window.browser.on("state", render);
  window.browser.state().then((s) => s && render(s));

  // Toolbar
  $("newtab").addEventListener("click", () => window.browser.newTab());
  $("back").addEventListener("click", () => window.browser.back());
  $("forward").addEventListener("click", () => window.browser.forward());
  $("reload").addEventListener("click", () => window.browser.reload());
  $("olo").addEventListener("click", () => { window.browser.panel(); setTimeout(() => $("question").focus(), 50); });
  $("panel-close").addEventListener("click", () => window.browser.panel(false));
  $("tasks").addEventListener("click", () => window.browser.newTab("polnet://tasks/"));
  $("member").addEventListener("click", () => (state?.member ? window.browser.newTab("polnet://wallet/") : window.browser.join()));
  $("address").addEventListener("focus", () => { editing = true; $("address").select(); });
  $("address").addEventListener("blur", () => { editing = false; if (state) render(state); });
  $("address").addEventListener("keydown", (e) => { if (e.key === "Escape") { editing = false; $("address").blur(); } });
  $("addressform").addEventListener("submit", (e) => {
    e.preventDefault();
    const v = $("address").value.trim();
    if (!v) return;
    editing = false;
    $("address").blur();
    window.browser.navigate(v);
  });
  window.browser.on("focus-address", () => $("address").focus());

  // Popovers sit over the page: while one is open the page is shown as a still picture (see ui:overlay).
  const pops = ["menu", "shield-pop", "report-pop"].map($);
  let overlaid = false;
  async function syncOverlay() {
    const open = pops.some((p) => !p.hidden);
    if (open === overlaid) return;
    overlaid = open;
    const bg = $("pagebg");
    if (open) {
      const pic = await window.browser.overlay(true);
      if (pic && overlaid) {
        bg.src = pic;
        bg.style.width = `${window.innerWidth - (state && state.panel ? 400 : 0)}px`;
        bg.hidden = false;
      }
    } else {
      bg.hidden = true;
      await window.browser.overlay(false);
    }
  }
  new MutationObserver(syncOverlay).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["hidden"] });

  // Menu
  const menu = $("menu");
  $("more").addEventListener("click", (e) => { e.stopPropagation(); menu.hidden = !menu.hidden; $("shield-pop").hidden = true; });
  document.addEventListener("click", (e) => {
    if (!menu.contains(e.target)) menu.hidden = true;
    if (!$("shield-pop").contains(e.target) && e.target !== $("shield") && !$("shield").contains(e.target)) $("shield-pop").hidden = true;
  });
  for (const b of menu.querySelectorAll("[data-go]")) b.addEventListener("click", () => { menu.hidden = true; window.browser.newTab(b.getAttribute("data-go")); });
  $("private-window").addEventListener("click", () => { menu.hidden = true; window.browser.privateWindow(); });
  $("signout").addEventListener("click", () => { menu.hidden = true; if (confirm("Sign out of POL Net on this computer? Your account, names and earnings stay; join again with one check.")) window.browser.signOut(); });
  function report() {
    menu.hidden = true;
    if (!state?.active?.host) return;
    $("report-title").textContent = `Report ${state.active.host}`;
    $("report-reason").value = "";
    $("report-result").hidden = true;
    $("report-send").disabled = false;
    $("report-pop").hidden = false;
    $("report-reason").focus();
  }
  $("report-cancel").addEventListener("click", () => { $("report-pop").hidden = true; });
  $("report-send").addEventListener("click", async () => {
    const reason = $("report-reason").value.trim() || "Scam or harmful site";
    $("report-send").disabled = true;
    const r = await window.browser.reportSite(reason);
    const out = $("report-result");
    out.hidden = false;
    out.textContent = r.error ? (r.message || "The report could not be sent.") : r.action === "site_flagged" ? "Thank you. Enough members agree: POL Net now warns everyone before this site opens." : `Thank you. ${r.reports} member${r.reports === 1 ? " has" : "s have"} reported this site.`;
    setTimeout(() => { $("report-pop").hidden = true; }, 3500);
  });
  $("report").addEventListener("click", report);
  window.browser.on("report-site", report);

  // Shields
  $("shield").addEventListener("click", (e) => {
    e.stopPropagation();
    const a = state?.active;
    if (!a?.host) return;
    $("shield-title").textContent = a.shields === false ? `Shields are off for ${a.host}` : `Shields are on for ${a.host}`;
    $("shield-text").textContent = a.shields === false
      ? "Trackers and third-party cookies are allowed on this site. Turn Shields back on to block them."
      : `${a.blocked || 0} tracker${a.blocked === 1 ? "" : "s"} blocked on this page. Third-party cookies are refused, tracking parameters are removed from links, plain http is upgraded to https, and every site is told you do not want to be tracked (Global Privacy Control).`;
    $("shield-toggle").textContent = a.shields === false ? "Turn Shields on" : "Turn Shields off for this site";
    $("shield-pop").hidden = !$("shield-pop").hidden;
    menu.hidden = true;
  });
  $("shield-toggle").addEventListener("click", () => { $("shield-pop").hidden = true; window.browser.toggleShields(); });

  // Olo
  const chat = $("chat");
  let current = null;
  let counter = 0;
  function add(cls, text) {
    const n = el("div", { class: `msg ${cls}` }, text);
    chat.append(n);
    chat.scrollTop = chat.scrollHeight;
    return n;
  }
  window.browser.on("olo-prefill", (text) => { $("question").value = `What does this mean: "${text}"`; $("includepage").checked = true; $("question").focus(); });
  window.browser.on("olo-event", ({ id, event }) => {
    if (!current || current.id !== id) return;
    if (event.type === "delta") {
      current.text += event.text;
      current.node.textContent = current.text;
      chat.scrollTop = chat.scrollHeight;
    } else if (event.type === "verification" && event.verification) {
      const v = event.verification;
      current.meta = `Zeus checked ${v.claims?.length ?? 0} sentence${v.claims?.length === 1 ? "" : "s"}: ${v.supported ?? 0} supported, ${v.contradicted ?? 0} contradicted, ${v.unsupported ?? 0} not covered.`;
    } else if (event.type === "sources" && Array.isArray(event.sources)) {
      current.sources = event.sources.slice(0, 6);
    }
  });
  $("question").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("askform").requestSubmit(); } });
  $("askform").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (current) { window.browser.oloStop(current.id); return; }
    const question = $("question").value.trim();
    if (!question) return;
    $("question").value = "";
    chat.querySelector(".hint")?.remove();
    add("you", question);
    current = { id: `q${++counter}`, text: "", node: add("olo", "..."), meta: "", sources: [] };
    $("askbtn").textContent = "Stop";
    const r = await window.browser.oloAsk({ id: current.id, question, includePage: $("includepage").checked });
    if (r?.error) {
      current.node.classList.add("err");
      current.node.textContent = r.message || "Olo could not answer.";
    } else {
      if (!current.text) current.node.textContent = r.text || "(no answer)";
      const bits = [];
      if (r.usedPage) bits.push("Read this page.");
      if (current.meta) bits.push(current.meta);
      if (bits.length) chat.append(el("div", { class: "meta" }, bits.join(" ")));
      for (const s of current.sources) {
        const link = el("a", { href: "#", class: "meta", onclick: (ev) => { ev.preventDefault(); window.browser.newTab(s.url); } }, `[${s.index}] ${s.title}`);
        chat.append(link);
      }
    }
    chat.scrollTop = chat.scrollHeight;
    current = null;
    $("askbtn").textContent = "Ask";
  });
})();
