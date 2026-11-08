"use strict";
(async () => {
  const { el } = P;
  const app = document.getElementById("app");
  const search = el("input", { placeholder: "Search your history", "aria-label": "Search history" });
  const list = el("div");
  const draw = async (clear) => {
    const rows = await window.polnet.history({ query: search.value, clear });
    list.replaceChildren(...(rows.length ? rows.map((r) => el("div", { class: "card row" }, el("div", { class: "grow" }, el("a", { href: r.url }, r.title || r.url), el("div", { class: "dim small" }, r.url)), el("span", { class: "dim small" }, P.when(r.at)))) : [el("p", { class: "dim" }, "Nothing here.")]));
  };
  search.addEventListener("input", () => draw());
  app.append(el("h1", {}, "History"), el("p", { class: "lead" }, "Kept on this computer only. Private windows keep none."),
    el("div", { class: "row" }, el("div", { class: "grow" }, search), el("button", { onclick: () => { if (confirm("Delete all history on this computer?")) draw(true); } }, "Clear history")), list);
  draw();
})();
