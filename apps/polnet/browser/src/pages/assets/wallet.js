"use strict";
(async () => {
  const { el, money } = P;
  const app = document.getElementById("app");
  app.append(el("h1", {}, "Wallet"), el("p", { class: "lead" }, "What you have earned on POL Net, in pounds and euros. Every entry is permanent: nothing is ever edited or deleted."));
  const body = el("div");
  app.append(body);
  const me = await P.member(body);
  if (!me) return;
  const r = await P.api("GET", "/v1/wallet");
  if (r.error) return body.append(el("p", { class: "error" }, P.errorText(r)));
  const out = el("p", { class: "small" });
  body.append(
    el("div", { class: "grid" },
      el("div", { class: "card" }, el("div", { class: "dim small" }, "Balance (GBP)"), el("div", { class: "money", style: "font-size:30px" }, money(r.balances.GBP, "GBP"))),
      el("div", { class: "card" }, el("div", { class: "dim small" }, "Balance (EUR)"), el("div", { class: "money", style: "font-size:30px" }, money(r.balances.EUR, "EUR")))),
    el("div", { class: "card" },
      el("h2", { style: "margin-top:0" }, "Get paid"),
      !r.payouts ? el("p", { class: "dim" }, "Payouts are not switched on yet. Your balance is safe in the ledger and can be paid out as soon as they are.")
        : !r.payouts_enabled ? el("div", {}, el("p", { class: "dim" }, "Payouts go to your bank account through Stripe. Stripe checks your identity and bank details once; POL Net never sees them."), el("button", { class: "primary", onclick: async () => { const x = await P.api("POST", "/v1/payouts/onboard", {}); if (x.onboarding_url) window.polnet.open(x.onboarding_url); else { out.className = "small error"; out.textContent = P.errorText(x); } } }, "Set up payouts with Stripe"), el("button", { onclick: async () => { await P.api("GET", "/v1/payouts/status"); location.reload(); } }, "I've finished setting up"))
          : el("div", {}, el("p", { class: "dim" }, `The smallest payout is ${money(r.min_payout_pence)}. Money usually reaches your bank in two to three working days.`),
            el("button", { class: "earn", disabled: r.balances.GBP < r.min_payout_pence, onclick: async (e) => { e.target.disabled = true; const x = await P.api("POST", "/v1/payouts", { currency: "GBP" }); out.className = x.error ? "small error" : "small"; out.textContent = x.error ? P.errorText(x) : `${money(x.paid_pence)} is on its way to your bank.`; setTimeout(() => location.reload(), 1500); } }, `Pay out ${money(r.balances.GBP)}`)),
      out),
    el("h2", {}, "History"),
    r.entries.length ? el("table", {}, el("tr", {}, el("th", {}, "When"), el("th", {}, "What"), el("th", {}, "Amount")),
      ...r.entries.map((e) => el("tr", {}, el("td", { class: "dim" }, P.when(e.created_at)), el("td", {}, { task_reward: "Task approved", payout: "Paid to your bank", payout_reversal: "Payout failed, returned" }[e.kind] || e.kind), el("td", { class: e.amount_pence >= 0 ? "money" : "" }, money(e.amount_pence, e.currency)))))
      : el("p", { class: "dim" }, "Nothing yet. Claim a task to start earning."),
    el("p", { class: "dim small" }, "Earnings from tasks may be taxable income. In the UK, the first £1,000 a year of trading income is usually tax free (the trading allowance); keep your own records. POL Net is not a tax adviser."),
  );
})();
