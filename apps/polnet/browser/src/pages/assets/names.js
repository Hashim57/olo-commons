"use strict";
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  app.append(el("h1", {}, "pol:// Names"), el("p", { class: "lead" }, "Give a site an address on the members' network. Only verified people can open pol:// addresses, and each site sees every visitor under a different id, so no one can track members across sites."));
  const body = el("div");
  app.append(body);
  const me = await P.member(body);
  if (!me) return;
  const name = el("input", { placeholder: "community-garden", maxlength: 32 });
  const target = el("input", { placeholder: "https://your-site.example/" });
  const desc = el("input", { placeholder: "What it is, in a line", maxlength: 200 });
  const out = el("p", { class: "small" });
  const list = el("div");
  async function draw() {
    const r = await P.api("GET", "/v1/names");
    if (r.error) return list.replaceChildren(el("p", { class: "error" }, P.errorText(r)));
    list.replaceChildren(...(r.names.length ? r.names.map((n) => el("div", { class: "card row" },
      el("div", { class: "grow" }, el("a", { href: `pol://${n.name}/` }, `pol://${n.name}`), el("div", { class: "dim small" }, `${n.target}${n.suspended ? " · taken down after reports, pending review" : ""}`)),
      el("button", { onclick: async () => { if (confirm(`Release pol://${n.name}? Someone else can then take it.`)) { await P.api("DELETE", `/v1/names/${n.name}`); draw(); } } }, "Release"))) : [el("p", { class: "dim" }, "You hold no names yet. Each member can hold up to five.")]));
  }
  body.append(el("div", { class: "card" }, el("strong", {}, "Register a name"),
    el("label", {}, "Name"), name, el("label", {}, "Where the site lives (https)"), target, el("label", {}, "Description"), desc,
    el("div", { class: "row", style: "margin-top:10px" }, el("button", { class: "primary", onclick: async () => {
      const r = await P.api("POST", "/v1/names", { name: name.value.trim().toLowerCase(), target: target.value.trim(), description: desc.value.trim() });
      out.className = r.error ? "small error" : "small"; out.textContent = r.error ? P.errorText(r) : `pol://${r.name.name} is yours.`;
      draw();
    } }, "Register")), out,
    el("details", {}, el("summary", {}, "For site owners: knowing a visitor is a verified member"),
      el("p", { class: "dim small" }, "Every request POL Net makes to your site carries an x-polnet-visit header: an ES256 token valid for ten minutes, with aud set to pol://your-name, typ \"visit\", and sub the visitor's id for your site alone. Check it against the keys at <server>/.well-known/jwks.json. A visit token cannot be used against POL Net itself."))),
    el("h2", {}, "Your names"), list);
  draw();
})();
