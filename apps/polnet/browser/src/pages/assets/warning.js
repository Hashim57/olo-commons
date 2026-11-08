"use strict";
(() => {
  const { el } = P;
  const q = new URLSearchParams(location.search);
  const kind = q.get("kind");
  const url = q.get("url") || "";
  const protectedMode = q.get("protected") === "1";
  let host = "";
  try { host = new URL(url).hostname; } catch { /* bad url */ }
  const app = document.getElementById("app");
  // Warnings shown after a page loaded (scam pages, the pause) sit on top of that page in history, so
  // "back" skips it too.
  const afterLoad = kind === "scam-page" || kind === "pause";
  const goBack = () => {
    if (history.length > (afterLoad ? 2 : 1)) history.go(afterLoad ? -2 : -1);
    else location.href = "polnet://newtab/";
  };
  const back = (label = "Go back") => el("button", { class: "primary", onclick: goBack }, label);

  /** "Open anyway": in protected mode it waits a few seconds first. Scams rely on hurry. */
  const proceed = (label) => {
    const b = el("button", { onclick: () => window.polnet.proceed(url, kind) }, label);
    if (protectedMode) {
      let left = 10;
      b.disabled = true;
      b.textContent = `${label} (${left})`;
      const t = setInterval(() => {
        left -= 1;
        if (left <= 0) {
          clearInterval(t);
          b.disabled = false;
          b.textContent = label;
        } else b.textContent = `${label} (${left})`;
      }, 1000);
    }
    return b;
  };
  const calm = protectedMode
    ? el("div", { class: "notice" }, "Take a breath. If someone is on the phone with you right now, or a message told you to hurry, stop and hang up. Call a person you trust on a number you already know. A real bank, police officer or company will never mind you checking.")
    : null;
  const helperNote = protectedMode ? el("p", { class: "dim small" }, "If you have helpers in Family help, they have been told the name of this site and that POL Net warned you. Nothing else.") : null;

  if (kind === "lookalike") {
    const official = q.get("official");
    document.title = "Warning: possible fake site";
    app.append(
      el("h1", { class: "error" }, "This may be a fake site"),
      el("p", { class: "lead" }, `${host} looks like ${q.get("brand")}, but it is not ${q.get("brand")}'s real address.`),
      el("div", { class: "notice" }, "Scam sites copy banks, parcel companies, tax offices and crypto wallets to steal passwords and card numbers. If a message sent you here, go to the real site yourself instead."),
      calm,
      el("div", { class: "row" }, el("button", { class: "primary", onclick: () => { location.href = `https://${official}/`; } }, `Go to the real ${official}`), proceed("I know this site, open it")),
      helperNote,
    );
  } else if (kind === "reported") {
    document.title = "Warning: reported site";
    app.append(
      el("h1", { class: "error" }, "Members have reported this site"),
      el("p", { class: "lead" }, `Three or more verified POL Net members have reported ${host} as a scam or as harmful.`),
      el("p", { class: "dim" }, "POL Net checked this without telling anyone which site you were opening: only a short fragment of a code made from the address was sent."),
      calm,
      el("div", { class: "row" }, back(), proceed("Open it anyway")),
      helperNote,
    );
  } else if (kind === "scam-page") {
    let reasons = [];
    try { reasons = JSON.parse(q.get("why") || "[]").filter((x) => typeof x === "string").slice(0, 8); } catch { reasons = []; }
    document.title = "Warning: this page looks like a scam";
    app.append(
      el("h1", { class: "error" }, "This page looks like a scam"),
      el("p", { class: "lead" }, `POL Net read ${host} on your computer, without sending it anywhere, and found the tricks scams use:`),
      el("div", { class: "card" }, el("ul", {}, ...reasons.map((r) => el("li", {}, r)))),
      el("p", {}, "Closing a page like this is always safe. Do not call any number on it, do not pay, and do not let anyone control your computer."),
      calm,
      el("div", { class: "row" }, back("Get me out of here"), proceed("I am sure it is fine, show it")),
      helperNote,
    );
  } else if (kind === "remote-access") {
    document.title = "Before you let anyone control your computer";
    app.append(
      el("h1", { class: "error" }, "Is someone asking you to install this?"),
      el("p", { class: "lead" }, `${host} makes software that lets another person see and control your computer.`),
      el("div", { class: "notice" }, "It is useful when you asked for help from someone you know. It is also the first thing scammers ask for when they phone pretending to be your bank, BT, Microsoft, Amazon or the police. Once they are in, they can empty accounts while you watch."),
      el("p", {}, "If a caller or a message asked you to come here: hang up, and call your bank or a person you trust on a number you already know."),
      calm,
      el("div", { class: "row" }, back("Nobody asked me, go back"), proceed("I asked someone I know for help")),
      helperNote,
    );
  } else if (kind === "pause") {
    const card = q.get("field") === "card";
    document.title = "A moment before you type";
    app.append(
      el("h1", {}, card ? "Before you enter card details" : "Before you enter a password"),
      el("p", { class: "lead" }, `This is the first time you have used ${host}. Three quick questions:`),
      el("div", { class: "card" }, el("ol", {},
        el("li", {}, "Did you come here by yourself, or did a message, a call or an advert send you?"),
        el("li", {}, "Are you being told to hurry, or that something bad will happen if you do not act now?"),
        el("li", {}, card ? "Is this a shop or service you chose, and does the price make sense?" : "Is this really where you normally sign in, or does it only look like it?"))),
      el("p", { class: "dim" }, "If any answer worries you, go back and open the real site yourself, or ask someone you trust."),
      calm,
      el("div", { class: "row" }, back(), proceed("I chose this site, continue")),
      helperNote,
    );
  } else if (kind === "http") {
    document.title = "Not encrypted";
    app.append(
      el("h1", {}, "This site has no secure version"),
      el("p", { class: "lead" }, `${host} does not offer https, so anyone on your network could read or change what you see and send.`),
      el("p", { class: "dim" }, "Do not type passwords or card numbers on it."),
      el("div", { class: "row" }, back(), proceed("Open it without encryption")),
    );
  } else {
    app.append(el("h1", {}, "Warning"));
  }
})();
