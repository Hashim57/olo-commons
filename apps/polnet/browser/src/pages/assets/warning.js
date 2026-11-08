"use strict";
(() => {
  const { el } = P;
  const q = new URLSearchParams(location.search);
  const kind = q.get("kind");
  const url = q.get("url") || "";
  let host = "";
  try { host = new URL(url).hostname; } catch { /* bad url */ }
  const app = document.getElementById("app");
  const proceed = (label) => el("button", { onclick: () => window.polnet.proceed(url, kind) }, label);
  if (kind === "lookalike") {
    const official = q.get("official");
    document.title = "Warning: possible fake site";
    app.append(
      el("h1", { class: "error" }, "This may be a fake site"),
      el("p", { class: "lead" }, `${host} looks like ${q.get("brand")}, but it is not ${q.get("brand")}'s real address.`),
      el("div", { class: "notice" }, "Scam sites copy banks, parcel companies, tax offices and crypto wallets to steal passwords and card numbers. If a message sent you here, go to the real site yourself instead."),
      el("div", { class: "row" }, el("button", { class: "primary", onclick: () => { location.href = `https://${official}/`; } }, `Go to the real ${official}`), proceed("I know this site, open it")),
    );
  } else if (kind === "reported") {
    document.title = "Warning: reported site";
    app.append(
      el("h1", { class: "error" }, "Members have reported this site"),
      el("p", { class: "lead" }, `Three or more verified POL Net members have reported ${host} as a scam or as harmful.`),
      el("p", { class: "dim" }, "POL Net checked this without telling anyone which site you were opening: only a short fragment of a code made from the address was sent."),
      el("div", { class: "row" }, el("button", { class: "primary", onclick: () => history.length > 1 ? history.back() : (location.href = "polnet://newtab/") }, "Go back"), proceed("Open it anyway")),
    );
  } else if (kind === "http") {
    document.title = "Not encrypted";
    app.append(
      el("h1", {}, "This site has no secure version"),
      el("p", { class: "lead" }, `${host} does not offer https, so anyone on your network could read or change what you see and send.`),
      el("p", { class: "dim" }, "Do not type passwords or card numbers on it."),
      el("div", { class: "row" }, el("button", { class: "primary", onclick: () => history.length > 1 ? history.back() : (location.href = "polnet://newtab/") }, "Go back"), proceed("Open it without encryption")),
    );
  } else {
    app.append(el("h1", {}, "Warning"));
  }
})();
