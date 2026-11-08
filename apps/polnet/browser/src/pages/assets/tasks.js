"use strict";
(async () => {
  const { el, money } = P;
  const app = document.getElementById("app");
  app.append(el("h1", {}, "Tasks that pay"), el("p", { class: "lead" }, "Real work for organisations that help people and places. Claim a task, do it, send your evidence; when the organisation approves it, the reward goes into your wallet."));
  const body = el("div");
  app.append(body);
  const me = await P.member(body);
  if (!me) return;
  const cfg = await window.polnet.config();
  const cats = (cfg && cfg.categories) || [];
  const filter = el("select", { "aria-label": "Category" }, el("option", { value: "" }, "All categories"), ...cats.map((c) => el("option", { value: c }, c.replace("-", " "))));
  const list = el("div");
  const mine = el("div");
  const toast = el("div", { class: "notice", role: "status" });
  toast.hidden = true;
  const say = (text, bad) => { toast.hidden = false; toast.className = bad ? "notice error" : "notice"; toast.textContent = text; };
  body.append(toast, el("div", { class: "row" }, el("div", { class: "grow" }, el("h2", {}, "Open tasks")), el("div", { style: "width:220px" }, filter)), list, el("h2", {}, "My tasks"), mine);

  async function drawOpen() {
    const r = await P.api("GET", `/v1/tasks${filter.value ? `?category=${encodeURIComponent(filter.value)}` : ""}`);
    if (r.error) return list.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
    if (!r.tasks.length) return list.replaceChildren(el("div", { class: "card dim" }, "No open tasks right now. New ones arrive as organisations fund them."));
    list.replaceChildren(...r.tasks.map((t) => {
      const msg = el("span", { class: "small" });
      return el("div", { class: "card" },
        el("div", { class: "row" }, el("strong", { class: "grow" }, t.title), el("span", { class: "money" }, money(t.reward_pence, t.currency))),
        el("p", {}, t.description),
        t.instructions ? el("details", {}, el("summary", {}, "How to do it"), el("p", { class: "dim" }, t.instructions)) : null,
        el("div", { class: "row small dim" }, el("span", { class: "tag" }, t.category), `${t.slots_left} of ${t.slots} places left`, t.deadline ? `Due ${P.when(t.deadline)}` : null),
        el("div", { class: "row", style: "margin-top:10px" }, el("button", { class: "earn", onclick: async (e) => {
          e.target.disabled = true;
          const c = await P.api("POST", `/v1/tasks/${t.id}/claim`, {});
          if (c.error) { msg.className = "small error"; msg.textContent = c.error === "already_claimed" ? "You already have this task." : c.error === "no_slots" ? "All places were just taken." : P.errorText(c); e.target.disabled = false; return; }
          say(`Claimed "${t.title}". You have 72 hours to send your evidence under My tasks.`);
          drawMine(); drawOpen();
        } }, "Claim this task"), msg));
    }));
  }

  async function drawMine() {
    const r = await P.api("GET", "/v1/claims");
    if (r.error) return mine.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
    if (!r.claims.length) return mine.replaceChildren(el("p", { class: "dim" }, "Tasks you claim appear here."));
    mine.replaceChildren(...r.claims.map((c) => {
      const status = { claimed: "Claimed: send your evidence", submitted: "Sent: waiting for the organisation", approved: "Approved: paid into your wallet", rejected: c.note === "expired" ? "Expired: no evidence within 72 hours" : "Not approved" }[c.status];
      const card = el("div", { class: "card" }, el("div", { class: "row" }, el("strong", { class: "grow" }, c.task ? c.task.title : "Task"), c.task ? el("span", { class: "money" }, money(c.task.reward_pence, c.task.currency)) : null), el("div", { class: "small dim" }, status), c.note && c.note !== "expired" ? el("p", { class: "small" }, `Note from the organisation: ${c.note}`) : null);
      if (c.status === "claimed" || c.status === "submitted") {
        const text = el("textarea", { rows: 3, placeholder: "What you did, what you found" });
        text.value = c.evidence_text || "";
        const link = el("input", { placeholder: "https:// link to photos, a document or data (optional)" });
        link.value = c.evidence_url || "";
        const out = el("span", { class: "small" });
        card.append(el("label", {}, "Your evidence"), text, link, el("div", { class: "row", style: "margin-top:8px" }, el("button", { class: "primary", onclick: async () => {
          const r2 = await P.api("POST", `/v1/claims/${c.id}/submit`, { evidence_text: text.value, evidence_url: link.value });
          out.className = r2.error ? "small error" : "small"; out.textContent = r2.error ? P.errorText(r2) : "Sent. The organisation reviews it next.";
          if (!r2.error) setTimeout(drawMine, 800);
        } }, c.status === "submitted" ? "Update evidence" : "Send evidence"), out));
      }
      return card;
    }));
  }

  filter.addEventListener("change", drawOpen);
  drawOpen();
  drawMine();

  if (me.role === "poster") {
    const org = el("div");
    body.append(el("h2", {}, "For your organisation"), org);
    const f = {
      title: el("input", { maxlength: 120 }), description: el("textarea", { rows: 3 }), instructions: el("textarea", { rows: 3 }),
      category: el("select", {}, ...cats.map((c) => el("option", { value: c }, c))), reward: el("input", { type: "number", min: "0.5", max: "1000", step: "0.5", value: "5" }),
      slots: el("input", { type: "number", min: "1", max: "1000", value: "10" }),
    };
    const out = el("p", { class: "small" });
    org.append(el("div", { class: "card" }, el("strong", {}, "Post a task"),
      el("label", {}, "Title"), f.title, el("label", {}, "What needs doing and why it matters"), f.description, el("label", {}, "How to do it, and what evidence to send"), f.instructions,
      el("div", { class: "row" }, el("div", { class: "grow" }, el("label", {}, "Category"), f.category), el("div", { class: "grow" }, el("label", {}, "Reward per person (£)"), f.reward), el("div", { class: "grow" }, el("label", {}, "People needed"), f.slots)),
      el("div", { class: "row", style: "margin-top:10px" }, el("button", { class: "primary", onclick: async () => {
        const r = await P.api("POST", "/v1/org/tasks", { title: f.title.value, description: f.description.value, instructions: f.instructions.value, category: f.category.value, reward_pence: Math.round(Number(f.reward.value) * 100), slots: Number(f.slots.value) });
        out.className = r.error ? "small error" : "small"; out.textContent = r.error ? P.errorText(r) : `Saved as a draft. Fund ${money(r.to_fund_pence)} (rewards plus the ${(cfg.fee_bps / 100).toFixed(0)}% platform fee) to open it to members.`;
        drawOrg();
      } }, "Save task")), out));
    const orgList = el("div");
    org.append(orgList);
    async function drawOrg() {
      const r = await P.api("GET", "/v1/org/tasks");
      if (r.error) return orgList.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
      orgList.replaceChildren(...r.tasks.map((t) => {
        const card = el("div", { class: "card" }, el("div", { class: "row" }, el("strong", { class: "grow" }, t.title), el("span", { class: "tag" }, t.status)));
        if (t.status === "draft") card.append(el("button", { class: "primary", onclick: async () => { const r2 = await P.api("POST", `/v1/org/tasks/${t.id}/fund`, {}); if (r2.checkout_url) window.polnet.open(r2.checkout_url); else alert(P.errorText(r2)); } }, "Fund with Stripe"));
        const claims = el("div");
        card.append(el("button", { class: "review", onclick: async () => {
          const r2 = await P.api("GET", `/v1/org/tasks/${t.id}/claims`);
          const refresh = () => card.querySelector(".review").click();
          claims.replaceChildren(...(r2.claims || []).filter((c) => c.status !== "claimed").map((c) => {
            const note = el("input", { placeholder: "A note to the member (optional)" });
            return el("div", { class: "card" },
              el("div", { class: "small dim" }, `Member ${c.member} · ${c.status}`), el("p", {}, c.evidence_text || ""),
              c.evidence_url ? el("a", { href: "#", onclick: (e) => { e.preventDefault(); window.polnet.open(c.evidence_url); } }, c.evidence_url) : null,
              c.status === "submitted" ? el("div", {}, note, el("div", { class: "row", style: "margin-top:8px" },
                el("button", { class: "earn", onclick: async () => { const x = await P.api("POST", `/v1/org/claims/${c.id}/approve`, { note: note.value }); if (x.error) alert(P.errorText(x)); else refresh(); } }, "Approve and pay"),
                el("button", { onclick: async () => { const x = await P.api("POST", `/v1/org/claims/${c.id}/reject`, { note: note.value }); if (x.error) alert(P.errorText(x)); else refresh(); } }, "Not approved"))) : null);
          }));
          if (!claims.children.length) claims.replaceChildren(el("p", { class: "dim small" }, "No evidence sent yet."));
        } }, "Review evidence"), claims);
        return card;
      }));
    }
    drawOrg();
  }
})();
