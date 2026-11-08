"use strict";
/**
 * POL Net: a browser that keeps you private, warns you before harm, connects verified people, and pays
 * you for real work that makes things better. The main process: windows and tabs, the Shields and
 * safety rules on every request, the polnet:// pages, the pol:// member layer, Olo, and the join flow.
 */
const { app, BrowserWindow, WebContentsView, Menu, dialog, ipcMain, net, protocol, safeStorage, session, shell, clipboard, webContents } = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const { Settings } = require("./settings");
const shields = require("./shields");
const safety = require("./safety");
const { toUrl, ENGINES } = require("./urlbar");
const { PolNet, allowedApi, parsePolUrl } = require("./polnet");
const { Olo } = require("./olo");

const UI_HEIGHT = 86;
const PANEL_WIDTH = 400;
const PAGES = path.join(__dirname, "..", "pages");
const NEW_TAB = "polnet://newtab/";
// A generic Chrome user agent: no "Electron", no "POLNet", so the browser does not stand out.
const USER_AGENT = `Mozilla/5.0 (${process.platform === "darwin" ? "Macintosh; Intel Mac OS X 10_15_7" : process.platform === "win32" ? "Windows NT 10.0; Win64; x64" : "X11; Linux x86_64"}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${process.versions.chrome.split(".")[0]}.0.0.0 Safari/537.36`;

protocol.registerSchemesAsPrivileged([
  { scheme: "polnet", privileges: { standard: true, secure: true, supportFetchAPI: true } },
  { scheme: "pol", privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true } },
]);

if (process.env.POLNET_USER_DATA) app.setPath("userData", process.env.POLNET_USER_DATA);
app.userAgentFallback = USER_AGENT;

let settings;
let polnet;
let olo;
const windows = new Set();
const preparedSessions = new WeakSet();
/** Hosts the person chose to visit despite a warning, for this run only. */
const trustedHosts = new Set();
/** Hosts the person allowed over plain http, for this run only. */
const httpExceptions = new Set();
const visitPasses = new Map();
let privateCounter = 0;

// ---------------------------------------------------------------------------------------------------
// Pages

function page(name, query = {}) {
  const q = new URLSearchParams(query).toString();
  return `polnet://${name}/${q ? `?${q}` : ""}`;
}

function html(body, status = 200) {
  return new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'" } });
}

function messagePage(title, text, extra = "") {
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  return html(`<!doctype html><meta charset="utf-8"><title>${esc(title)}</title><style>body{font:16px/1.55 -apple-system,system-ui,sans-serif;max-width:620px;margin:12vh auto;padding:0 24px;color:#1d1d1f}h1{font-weight:600;font-size:26px}a{color:#0a63c9}</style><h1>${esc(title)}</h1><p>${esc(text)}</p>${extra}`);
}

function servePolnet(req) {
  const u = new URL(req.url);
  const host = u.hostname;
  let file;
  if (host === "assets") file = path.join(PAGES, "assets", path.normalize(u.pathname).replace(/^(\.\.[/\\])+/, ""));
  else file = path.join(PAGES, `${host}.html`);
  if (!file.startsWith(PAGES) || !fs.existsSync(file)) return messagePage("Not found", "There is no POL Net page at this address.");
  const type = file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : file.endsWith(".svg") ? "image/svg+xml" : "text/html; charset=utf-8";
  return new Response(fs.readFileSync(file), {
    headers: {
      "content-type": type,
      "content-security-policy": "default-src 'none'; script-src polnet://assets; style-src polnet://assets 'unsafe-inline'; img-src polnet://assets data: https:; connect-src 'none'; base-uri 'none'; form-action 'none'",
    },
  });
}

// ---------------------------------------------------------------------------------------------------
// The pol:// member layer (protocol stage 1: names in the members' registry, sites on https origins)

async function visitPassFor(name) {
  const hit = visitPasses.get(name);
  if (hit && Date.now() - hit.at < 8 * 60_000) return hit.token;
  const token = await polnet.visitPass(name);
  if (token) visitPasses.set(name, { at: Date.now(), token });
  return token;
}

async function servePol(req) {
  const parsed = parsePolUrl(req.url);
  if (!parsed) return messagePage("Not a POL Net address", "pol:// addresses are a name of 3 to 32 letters, digits and hyphens, like pol://community-garden.");
  if (!settings.pass()) {
    return messagePage("Members only", `pol://${parsed.name} is on the members' network. Join POL Net once, with a quick check that you are a real person, and every pol:// site opens.`, `<p><a href="polnet://join/">Join POL Net</a></p>`);
  }
  const rec = await polnet.resolve(parsed.name);
  if (rec.status === 401) return messagePage("Your pass has expired", "Open the member badge in the toolbar and join again: it takes a few seconds.", `<p><a href="polnet://join/">Renew my pass</a></p>`);
  if (rec.status === 404) return messagePage(`pol://${parsed.name} is free`, "Nobody has registered this name yet. Members can register it in Names.", `<p><a href="polnet://names/">Register it</a></p>`);
  if (rec.status === 451) return messagePage("Taken down", rec.message || "This site was taken down after reports from members, pending review.");
  if (rec.status !== 200) return messagePage("POL Net is not reachable", rec.message || "The members' registry did not answer. Try again in a moment.");
  const base = new URL(rec.target.endsWith("/") ? rec.target : `${rec.target}/`);
  const target = new URL(parsed.path.replace(/^\//, ""), base);
  if (target.origin !== base.origin) return messagePage("Blocked", "That address leaves the member site.");
  const visit = await visitPassFor(parsed.name);
  const headers = new Headers();
  for (const [k, v] of req.headers) if (!["host", "cookie", "origin", "referer"].includes(k.toLowerCase())) headers.set(k, v);
  if (visit) headers.set("x-polnet-visit", visit);
  headers.set("x-polnet-name", parsed.name);
  let res;
  try {
    res = await net.fetch(target.toString(), { method: req.method, headers, body: ["GET", "HEAD"].includes(req.method) ? undefined : req.body, redirect: "manual", duplex: "half", bypassCustomProtocolHandlers: true });
  } catch {
    return messagePage("The site did not answer", `pol://${parsed.name} is registered, but its server is not reachable right now.`);
  }
  if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
    const loc = new URL(res.headers.get("location"), target);
    if (loc.origin === base.origin) return new Response(null, { status: 302, headers: { location: `pol://${parsed.name}${loc.pathname}${loc.search}` } });
    return messagePage("This site sends you elsewhere", `pol://${parsed.name} wants to send you to ${loc.origin}, outside the members' network.`, `<p><a href="${loc.toString().replace(/"/g, "%22")}">Continue to ${loc.hostname}</a></p>`);
  }
  const out = new Headers(res.headers);
  out.delete("content-encoding");
  out.delete("content-length");
  return new Response(res.body, { status: res.status, headers: out });
}

// ---------------------------------------------------------------------------------------------------
// Sessions: Shields, safety, permissions and downloads on every request

function tabOfWebContentsId(id) {
  for (const w of windows) for (const t of w.tabs) if (t.view.webContents.id === id) return { win: w, tab: t };
  return null;
}

function warningFor(host) {
  if (trustedHosts.has(host)) return null;
  const look = safety.lookalike(host);
  if (look) return { kind: "lookalike", brand: look.brand, official: look.official, why: look.why };
  return null;
}

function prepareSession(ses, { isPrivate }) {
  if (preparedSessions.has(ses)) return;
  preparedSessions.add(ses);
  ses.setUserAgent(USER_AGENT);
  ses.protocol.handle("polnet", servePolnet);
  ses.protocol.handle("pol", servePol);

  ses.webRequest.onBeforeRequest({ urls: ["http://*/*", "https://*/*"] }, async (details, callback) => {
    const wc = details.webContentsId ? webContents.fromId(details.webContentsId) : null;
    const found = details.webContentsId ? tabOfWebContentsId(details.webContentsId) : null;
    const mainFrame = details.resourceType === "mainFrame";
    let topUrl = null;
    try {
      topUrl = mainFrame ? details.url : wc?.getURL() || null;
    } catch {
      topUrl = null;
    }
    let topHost = "";
    try {
      topHost = topUrl ? new URL(topUrl).hostname : "";
    } catch { /* not a URL */ }
    const shieldsOn = settings.siteShieldsOn(topHost);
    if (mainFrame && found) {
      found.tab.blocked = 0;
      const host = new URL(details.url).hostname;
      const warn = warningFor(host) || (settings.data.safetyList && settings.pass() && !trustedHosts.has(host) && (await Promise.race([polnet.flagged(host, safety.hostHash), new Promise((r) => setTimeout(() => r(false), 1500))])) ? { kind: "reported" } : null);
      if (warn) {
        callback({ cancel: true });
        setImmediate(() => found.tab.view.webContents.loadURL(page("warning", { ...warn, url: details.url })));
        return;
      }
    }
    const d = shields.decide({ url: details.url, resourceType: details.resourceType, topUrl, shieldsOn, httpExceptions });
    if (d.reason === "https" && !settings.data.httpsOnly) return callback({});
    if (d.cancel && found) {
      found.tab.blocked = (found.tab.blocked || 0) + 1;
      pushState(found.win);
    }
    if (d.redirectURL && d.reason === "https" && mainFrame && found) found.tab.upgradedFrom = details.url;
    callback(d.cancel ? { cancel: true } : d.redirectURL ? { redirectURL: d.redirectURL } : {});
  });

  ses.webRequest.onBeforeSendHeaders({ urls: ["http://*/*", "https://*/*"] }, (details, callback) => {
    const wc = details.webContentsId ? webContents.fromId(details.webContentsId) : null;
    let topUrl = null;
    try {
      topUrl = details.resourceType === "mainFrame" ? null : wc?.getURL() || null;
    } catch { /* gone */ }
    let host = "";
    try { host = topUrl ? new URL(topUrl).hostname : ""; } catch { /* not a URL */ }
    callback({ requestHeaders: shields.privacyHeaders(details.requestHeaders, { thirdParty: shields.isThirdParty(details.url, topUrl), shieldsOn: settings.siteShieldsOn(host) }) });
  });

  ses.webRequest.onHeadersReceived({ urls: ["http://*/*", "https://*/*"] }, (details, callback) => {
    const wc = details.webContentsId ? webContents.fromId(details.webContentsId) : null;
    let topUrl = null;
    try {
      topUrl = details.resourceType === "mainFrame" ? null : wc?.getURL() || null;
    } catch { /* gone */ }
    let host = "";
    try { host = topUrl ? new URL(topUrl).hostname : ""; } catch { /* not a URL */ }
    callback({ responseHeaders: shields.stripThirdPartySetCookie(details.responseHeaders, { thirdParty: shields.isThirdParty(details.url, topUrl), shieldsOn: settings.siteShieldsOn(host) }) });
  });

  const ASK = new Set(["media", "geolocation", "notifications", "midi", "midiSysex", "hid", "serial", "usb", "idle-detection", "display-capture", "openExternal", "clipboard-read", "storage-access", "top-level-storage-access"]);
  const ALWAYS = new Set(["clipboard-sanitized-write", "fullscreen", "pointerLock", "window-management"]);
  ses.setPermissionRequestHandler((wc, permission, callback, details) => {
    if (ALWAYS.has(permission)) return callback(true);
    let origin = "";
    try { origin = new URL(details.requestingUrl || wc.getURL()).origin; } catch { return callback(false); }
    if (origin.startsWith("polnet:")) return callback(false);
    if (!ASK.has(permission)) return callback(false);
    const remembered = isPrivate ? null : settings.permission(origin, permission);
    if (remembered !== null) return callback(remembered === "allow");
    const win = BrowserWindow.fromWebContents(wc) || [...windows][0]?.win;
    const words = { media: "use your camera or microphone", geolocation: "know your location", notifications: "send you notifications", openExternal: "open another app", "display-capture": "see your screen", "clipboard-read": "read your clipboard" }[permission] || `use ${permission}`;
    dialog.showMessageBox(win, { type: "question", buttons: ["Block", "Allow"], defaultId: 0, cancelId: 0, message: `${origin} wants to ${words}.`, detail: "POL Net blocks this unless you allow it.", checkboxLabel: isPrivate ? undefined : "Remember for this site", checkboxChecked: false })
      .then(({ response, checkboxChecked }) => {
        const allow = response === 1;
        if (checkboxChecked && !isPrivate) settings.setPermission(origin, permission, allow ? "allow" : "deny");
        callback(allow);
      })
      .catch(() => callback(false));
  });
  ses.setPermissionCheckHandler((wc, permission, origin) => {
    if (ALWAYS.has(permission)) return true;
    return !isPrivate && settings.permission(origin, permission) === "allow";
  });

  ses.on("will-download", (event, item, wc) => {
    const name = item.getFilename();
    if (safety.riskyDownload(name)) {
      const win = BrowserWindow.fromWebContents(wc) || [...windows][0]?.win;
      const answer = dialog.showMessageBoxSync(win, { type: "warning", buttons: ["Cancel", "Download anyway"], defaultId: 0, cancelId: 0, message: `${name} can run programs on your computer.`, detail: "Only download it if you trust where it came from. Scammers often send files like this pretending to be invoices, parcels or software updates." });
      if (answer !== 1) item.cancel();
    }
  });
}

// ---------------------------------------------------------------------------------------------------
// Windows and tabs

function createWindow({ isPrivate = false, url } = {}) {
  const partition = isPrivate ? `private-${++privateCounter}` : "persist:polnet";
  const ses = session.fromPartition(partition);
  prepareSession(ses, { isPrivate });
  const win = new BrowserWindow({
    width: 1320, height: 860, minWidth: 720, minHeight: 480, show: !process.env.POLNET_HIDDEN,
    title: isPrivate ? "POL Net (private)" : "POL Net",
    backgroundColor: isPrivate ? "#1b1530" : "#f6f6f3",
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    webPreferences: { preload: path.join(__dirname, "uiPreload.js"), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  const w = { win, ses, isPrivate, tabs: [], active: null, panel: false, nextTabId: 1 };
  windows.add(w);
  win.loadFile(path.join(__dirname, "..", "ui", "index.html"), { query: { private: isPrivate ? "1" : "0", platform: process.platform } });
  win.on("resize", () => layout(w));
  win.on("closed", () => {
    windows.delete(w);
    if (isPrivate) ses.clearStorageData().catch(() => undefined);
  });
  win.webContents.once("did-finish-load", () => {
    createTab(w, url || NEW_TAB);
  });
  return w;
}

function layout(w) {
  if (w.win.isDestroyed()) return;
  const [width, height] = w.win.getContentSize();
  for (const t of w.tabs) {
    if (t.id === w.active) t.view.setBounds({ x: 0, y: UI_HEIGHT, width: Math.max(200, width - (w.panel ? PANEL_WIDTH : 0)), height: Math.max(100, height - UI_HEIGHT) });
    t.view.setVisible(t.id === w.active && !w.overlay);
  }
}

function createTab(w, url, { background = false } = {}) {
  const view = new WebContentsView({
    webPreferences: { session: w.ses, preload: path.join(__dirname, "tabPreload.js"), contextIsolation: true, sandbox: true, nodeIntegration: false, webviewTag: false, safeDialogs: true },
  });
  const tab = { id: w.nextTabId++, view, blocked: 0, title: "New tab", favicon: null, loading: false, upgradedFrom: null };
  w.tabs.push(tab);
  w.win.contentView.addChildView(view);
  const wc = view.webContents;
  wc.setWebRTCIPHandlingPolicy("default_public_interface_only");
  wc.setWindowOpenHandler(({ url: target, disposition }) => {
    if (/^(https?|pol|polnet):/.test(target)) createTab(w, target, { background: disposition === "background-tab" });
    return { action: "deny" };
  });
  wc.on("page-title-updated", (_e, title) => { tab.title = title; pushState(w); });
  wc.on("page-favicon-updated", (_e, icons) => { tab.favicon = icons.find((i) => /^https:|^data:/.test(i)) || null; pushState(w); });
  wc.on("did-start-loading", () => { tab.loading = true; pushState(w); });
  wc.on("did-stop-loading", () => { tab.loading = false; pushState(w); });
  wc.on("did-navigate", (_e, navUrl) => {
    tab.favicon = null;
    if (!w.isPrivate) settings.addHistory(navUrl, wc.getTitle());
    pushState(w);
  });
  wc.on("did-navigate-in-page", () => pushState(w));
  wc.on("did-fail-load", (_e, code, desc, failedUrl, isMainFrame) => {
    if (!isMainFrame || code === -3) return;
    // An http site that has no https version: say so, and let the person choose.
    if (tab.upgradedFrom && failedUrl.startsWith("https://") && failedUrl.replace(/^https:/, "http:").split("#")[0] === tab.upgradedFrom.split("#")[0]) {
      const from = tab.upgradedFrom;
      tab.upgradedFrom = null;
      wc.loadURL(page("warning", { kind: "http", url: from }));
    }
  });
  wc.on("context-menu", (_e, params) => contextMenu(w, tab, params));
  wc.on("before-input-event", (event, input) => {
    if (input.type === "keyDown" && (input.meta || input.control) && input.key.toLowerCase() === "l") {
      event.preventDefault();
      w.win.webContents.focus();
      w.win.webContents.send("focus-address");
    }
  });
  if (!background || w.active === null) w.active = tab.id;
  layout(w);
  navigate(w, tab, url);
  pushState(w);
  return tab;
}

function activeTab(w) {
  return w.tabs.find((t) => t.id === w.active) || null;
}

function navigate(w, tab, input) {
  const url = toUrl(input, settings.data.search);
  if (!url) return;
  if (url.startsWith("polnet://join")) {
    openJoin(w);
    if (tab.view.webContents.getURL()) return;
    tab.view.webContents.loadURL(NEW_TAB);
    return;
  }
  tab.upgradedFrom = null;
  tab.view.webContents.loadURL(url).catch(() => undefined);
}

function closeTab(w, id) {
  const i = w.tabs.findIndex((t) => t.id === id);
  if (i < 0) return;
  const [tab] = w.tabs.splice(i, 1);
  w.win.contentView.removeChildView(tab.view);
  tab.view.webContents.close();
  if (w.tabs.length === 0) {
    w.win.close();
    return;
  }
  if (w.active === id) w.active = (w.tabs[i] || w.tabs[i - 1]).id;
  layout(w);
  pushState(w);
}

function stateOf(w) {
  const t = activeTab(w);
  let url = "";
  let host = "";
  try {
    url = t ? t.view.webContents.getURL() : "";
    host = url.startsWith("http") ? new URL(url).hostname : "";
  } catch { /* gone */ }
  const member = settings.get().member;
  return {
    private: w.isPrivate,
    panel: w.panel,
    member: settings.pass() && member ? { handle: member.handle } : null,
    tabs: w.tabs.map((x) => ({ id: x.id, title: x.title || x.view.webContents.getURL() || "New tab", loading: x.loading, favicon: x.favicon, url: x.view.webContents.getURL() })),
    active: t ? {
      id: t.id, url: url === NEW_TAB ? "" : url, title: t.title, host,
      canBack: t.view.webContents.navigationHistory.canGoBack(), canForward: t.view.webContents.navigationHistory.canGoForward(),
      blocked: t.blocked || 0, shields: host ? settings.siteShieldsOn(host) : null,
      secure: url.startsWith("https://") || url.startsWith("pol://") || url.startsWith("polnet://"),
      member: url.startsWith("pol://"),
    } : null,
    engine: ENGINES[settings.data.search]?.name || "DuckDuckGo",
  };
}

function pushState(w) {
  if (!w.win.isDestroyed()) w.win.webContents.send("state", stateOf(w));
}

function pushAll() {
  for (const w of windows) pushState(w);
}

function windowOf(sender) {
  for (const w of windows) if (w.win.webContents === sender) return w;
  return null;
}

function contextMenu(w, tab, p) {
  const wc = tab.view.webContents;
  const items = [];
  if (p.linkURL) {
    items.push({ label: "Open link in new tab", click: () => createTab(w, p.linkURL, { background: true }) });
    items.push({ label: "Open link in private window", click: () => createWindow({ isPrivate: true, url: p.linkURL }) });
    items.push({ label: "Copy link", click: () => clipboard.writeText(p.linkURL) });
    items.push({ type: "separator" });
  }
  if (p.selectionText) {
    items.push({ label: "Copy", role: "copy" });
    items.push({ label: `Ask Olo about "${p.selectionText.slice(0, 30)}${p.selectionText.length > 30 ? "..." : ""}"`, click: () => { w.panel = true; layout(w); pushState(w); w.win.webContents.send("olo-prefill", p.selectionText.slice(0, 2000)); } });
    items.push({ type: "separator" });
  }
  if (p.isEditable) items.push({ label: "Paste", role: "paste" }, { label: "Select all", role: "selectAll" }, { type: "separator" });
  items.push({ label: "Back", enabled: wc.navigationHistory.canGoBack(), click: () => wc.navigationHistory.goBack() });
  items.push({ label: "Forward", enabled: wc.navigationHistory.canGoForward(), click: () => wc.navigationHistory.goForward() });
  items.push({ label: "Reload", click: () => wc.reload() });
  if (/^https?:/.test(wc.getURL())) items.push({ type: "separator" }, { label: "Report this site as a scam...", click: () => w.win.webContents.send("report-site") });
  Menu.buildFromTemplate(items).popup({ window: w.win });
}

// ---------------------------------------------------------------------------------------------------
// Join (one Proof-of-Life check) and the member pass

let joinWindow = null;

function openJoin(w) {
  if (joinWindow && !joinWindow.isDestroyed()) return joinWindow.focus();
  const server = settings.data.server;
  joinWindow = new BrowserWindow({
    parent: w?.win, width: 560, height: 760, title: "Join POL Net", show: !process.env.POLNET_HIDDEN,
    webPreferences: { partition: "polnet-join", preload: path.join(__dirname, "joinPreload.js"), contextIsolation: true, sandbox: true, additionalArguments: [`--polnet-server=${new URL(server).origin}`] },
  });
  prepareSession(joinWindow.webContents.session, { isPrivate: true });
  joinWindow.loadURL(`${server}/join`).catch(() => {
    joinWindow?.loadURL(`data:text/html,${encodeURIComponent(`<meta charset="utf-8"><body style="font:16px system-ui;margin:40px"><h2>POL Net is not reachable</h2><p>The server at ${server.replace(/[<>&"]/g, "")} did not answer. Check the server address in Settings.</p>`)}`);
  });
  joinWindow.on("closed", () => { joinWindow = null; });
}

async function acceptPass(pass) {
  const r = await new PolNet({ server: () => settings.data.server, pass, fetch: net.fetch.bind(net) }).call("GET", "/v1/me");
  if (r.status !== 200 || !r.member) return false;
  settings.setPass(pass, { handle: r.member.handle, id: r.member.id, role: r.member.role });
  visitPasses.clear();
  polnet.names.clear();
  pushAll();
  return true;
}

// ---------------------------------------------------------------------------------------------------
// IPC: the toolbar (uiPreload) and the browser's own pages (tabPreload)

function fromPolnetPage(event) {
  const url = event.senderFrame?.url || "";
  return url.startsWith("polnet://");
}

function registerIpc() {
  const onWin = (fn) => (event, ...args) => {
    const w = windowOf(event.sender);
    if (w) return fn(w, ...args);
  };
  ipcMain.on("ui:new-tab", onWin((w, url) => createTab(w, url || NEW_TAB)));
  ipcMain.on("ui:close-tab", onWin((w, id) => closeTab(w, id ?? w.active)));
  ipcMain.on("ui:activate", onWin((w, id) => { w.active = id; layout(w); pushState(w); }));
  ipcMain.on("ui:navigate", onWin((w, input) => { const t = activeTab(w); if (t) navigate(w, t, input); }));
  ipcMain.on("ui:back", onWin((w) => activeTab(w)?.view.webContents.navigationHistory.goBack()));
  ipcMain.on("ui:forward", onWin((w) => activeTab(w)?.view.webContents.navigationHistory.goForward()));
  ipcMain.on("ui:reload", onWin((w) => activeTab(w)?.view.webContents.reload()));
  ipcMain.on("ui:stop", onWin((w) => activeTab(w)?.view.webContents.stop()));
  ipcMain.on("ui:panel", onWin((w, open) => { w.panel = open ?? !w.panel; layout(w); pushState(w); }));
  // A menu or popover is open over the page: the page view sits above the toolbar's own drawing, so it is
  // swapped for a still picture of itself until the popover closes.
  ipcMain.handle("ui:overlay", async (event, open) => {
    const w = windowOf(event.sender);
    const t = w && activeTab(w);
    if (!t) return null;
    if (!open) {
      w.overlay = false;
      layout(w);
      return null;
    }
    let picture = null;
    try {
      picture = (await t.view.webContents.capturePage()).toDataURL();
    } catch { picture = null; }
    w.overlay = true;
    t.view.setVisible(false);
    return picture;
  });
  ipcMain.on("ui:private-window", () => createWindow({ isPrivate: true }));
  ipcMain.on("ui:join", onWin((w) => openJoin(w)));
  ipcMain.on("ui:sign-out", () => { settings.setPass(null); visitPasses.clear(); pushAll(); });
  ipcMain.on("ui:toggle-shields", onWin((w) => {
    const s = stateOf(w);
    if (!s.active?.host) return;
    settings.setSiteShields(s.active.host, !s.active.shields);
    activeTab(w)?.view.webContents.reload();
    pushState(w);
  }));
  ipcMain.handle("ui:state", (event) => { const w = windowOf(event.sender); return w ? stateOf(w) : null; });
  ipcMain.handle("ui:report-site", async (event, reason) => {
    const w = windowOf(event.sender);
    const s = w && stateOf(w);
    if (!s?.active?.host) return { error: "no_site" };
    if (!settings.pass()) return { error: "join_first", message: "Join POL Net to report sites: reports come from verified people, so they cannot be faked by bots." };
    return polnet.call("POST", "/v1/reports", { kind: "site", target: s.active.host, reason: String(reason || "scam").slice(0, 1000) });
  });

  const asks = new Map();
  ipcMain.handle("ui:olo-ask", async (event, { id, question, includePage }) => {
    const w = windowOf(event.sender);
    if (!w || typeof question !== "string" || !question.trim()) return { error: "empty" };
    let pageCtx = null;
    const t = activeTab(w);
    if (includePage && t && /^(https?|pol):/.test(t.view.webContents.getURL())) {
      try {
        const text = await t.view.webContents.executeJavaScript("document.body ? document.body.innerText.slice(0, 20000) : ''", true);
        pageCtx = { title: t.view.webContents.getTitle(), url: t.view.webContents.getURL(), text };
      } catch { pageCtx = null; }
    }
    const controller = new AbortController();
    asks.set(id, controller);
    try {
      const full = await olo.ask({ question: question.slice(0, 4000), page: pageCtx, privateChat: w.isPrivate || settings.data.oloPrivate !== false }, (e) => {
        if (!w.win.isDestroyed()) w.win.webContents.send("olo-event", { id, event: e });
      }, controller.signal);
      return { ok: true, text: full, usedPage: Boolean(pageCtx) };
    } catch (e) {
      return { error: "olo", message: e instanceof Error ? e.message : String(e) };
    } finally {
      asks.delete(id);
    }
  });
  ipcMain.on("ui:olo-stop", (_e, id) => asks.get(id)?.abort());

  // The browser's own pages
  ipcMain.handle("page:status", (event) => {
    if (!fromPolnetPage(event)) return null;
    return { member: settings.pass() ? settings.get().member : null, server: settings.data.server, engines: ENGINES, settings: settings.get() };
  });
  ipcMain.handle("page:api", async (event, { method, path: p, body }) => {
    if (!fromPolnetPage(event)) return { error: "forbidden" };
    if (!allowedApi(method, p)) return { error: "not_allowed" };
    const r = await polnet.call(method, p, body);
    if (r.status === 401 && settings.pass()) {
      settings.setPass(null);
      pushAll();
    }
    return r;
  });
  ipcMain.handle("page:config", async (event) => (fromPolnetPage(event) ? polnet.call("GET", "/v1/config", undefined, { auth: false }) : null));
  ipcMain.on("page:join", (event) => { if (fromPolnetPage(event)) openJoin([...windows].find((w) => w.tabs.some((t) => t.view.webContents === event.sender))); });
  ipcMain.on("page:open", (event, url) => {
    if (!fromPolnetPage(event) || typeof url !== "string") return;
    if (/^https:\/\/(connect\.stripe\.com|checkout\.stripe\.com|dashboard\.stripe\.com)\//.test(url)) return void shell.openExternal(url);
    const found = tabOfWebContentsId(event.sender.id);
    if (found && /^(https?|pol|polnet):/.test(url)) createTab(found.win, url);
  });
  ipcMain.handle("page:settings", (event, patch) => {
    if (!(event.senderFrame?.url || "").startsWith("polnet://settings")) return null;
    const out = patch ? settings.set(patch) : settings.get();
    polnet.names.clear();
    pushAll();
    return out;
  });
  ipcMain.handle("page:history", (event, { query, clear } = {}) => {
    if (!(event.senderFrame?.url || "").startsWith("polnet://")) return [];
    if (clear) settings.clearHistory();
    return settings.history(query);
  });
  ipcMain.handle("page:clear-data", async (event) => {
    if (!(event.senderFrame?.url || "").startsWith("polnet://settings")) return false;
    settings.clearHistory();
    await session.fromPartition("persist:polnet").clearStorageData();
    await session.fromPartition("persist:polnet").clearCache();
    return true;
  });
  ipcMain.on("page:proceed", (event, { url, kind }) => {
    if (!(event.senderFrame?.url || "").startsWith("polnet://warning")) return;
    const found = tabOfWebContentsId(event.sender.id);
    if (!found) return;
    try {
      const host = new URL(url).hostname;
      if (kind === "http") httpExceptions.add(host);
      else trustedHosts.add(host);
      found.tab.view.webContents.loadURL(url);
    } catch { /* bad url */ }
  });
  ipcMain.handle("join:complete", async (event, pass) => {
    const server = new URL(settings.data.server).origin;
    const sender = event.senderFrame?.url || "";
    if (!sender.startsWith(server + "/") || typeof pass !== "string" || pass.length > 4096) return false;
    const ok = await acceptPass(pass);
    if (ok) setTimeout(() => { if (joinWindow && !joinWindow.isDestroyed()) joinWindow.close(); }, 1200);
    return ok;
  });
}

function buildMenu() {
  const focused = () => [...windows].find((w) => w.win.isFocused()) || [...windows][0];
  const template = [
    ...(process.platform === "darwin" ? [{ role: "appMenu" }] : []),
    {
      label: "File",
      submenu: [
        { label: "New Tab", accelerator: "CmdOrCtrl+T", click: () => { const w = focused(); if (w) createTab(w, NEW_TAB); else createWindow(); } },
        { label: "New Window", accelerator: "CmdOrCtrl+N", click: () => createWindow() },
        { label: "New Private Window", accelerator: "CmdOrCtrl+Shift+N", click: () => createWindow({ isPrivate: true }) },
        { type: "separator" },
        { label: "Close Tab", accelerator: "CmdOrCtrl+W", click: () => { const w = focused(); if (w) closeTab(w, w.active); } },
      ],
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { label: "Reload", accelerator: "CmdOrCtrl+R", click: () => activeTab(focused())?.view.webContents.reload() },
        { label: "Back", accelerator: "CmdOrCtrl+[", click: () => activeTab(focused())?.view.webContents.navigationHistory.goBack() },
        { label: "Forward", accelerator: "CmdOrCtrl+]", click: () => activeTab(focused())?.view.webContents.navigationHistory.goForward() },
        { label: "Ask Olo", accelerator: "CmdOrCtrl+Shift+O", click: () => { const w = focused(); if (w) { w.panel = !w.panel; layout(w); pushState(w); } } },
        { type: "separator" },
        { label: "Developer Tools", accelerator: process.platform === "darwin" ? "Alt+Cmd+I" : "Ctrl+Shift+I", click: () => activeTab(focused())?.view.webContents.toggleDevTools() },
        { role: "togglefullscreen" },
      ],
    },
    {
      label: "POL Net",
      submenu: [
        { label: "Tasks that pay", click: () => { const w = focused(); if (w) createTab(w, "polnet://tasks/"); } },
        { label: "Wallet", click: () => { const w = focused(); if (w) createTab(w, "polnet://wallet/"); } },
        { label: "pol:// Names", click: () => { const w = focused(); if (w) createTab(w, "polnet://names/"); } },
        { label: "History", accelerator: "CmdOrCtrl+Y", click: () => { const w = focused(); if (w) createTab(w, "polnet://history/"); } },
        { label: "Settings", accelerator: "CmdOrCtrl+,", click: () => { const w = focused(); if (w) createTab(w, "polnet://settings/"); } },
        { type: "separator" },
        { label: "About POL Net", click: () => { const w = focused(); if (w) createTab(w, "polnet://about/"); } },
      ],
    },
    { role: "windowMenu" },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

app.on("web-contents-created", (_e, contents) => {
  // No page may load a <webview> or open the file system; navigation to file:// is refused everywhere.
  contents.on("will-attach-webview", (event) => event.preventDefault());
  contents.on("will-navigate", (event, url) => {
    if (url.startsWith("file:")) event.preventDefault();
  });
});

app.whenReady().then(() => {
  settings = new Settings(app.getPath("userData"), safeStorage);
  polnet = new PolNet({ server: () => settings.data.server, pass: () => settings.pass(), fetch: net.fetch.bind(net) });
  olo = new Olo({ base: () => settings.data.olo, token: () => settings.oloToken(), setToken: (t) => settings.setOloToken(t), fetch: net.fetch.bind(net) });
  registerIpc();
  buildMenu();
  // A pass is refreshed each time the browser starts, so an active member never has to join again.
  if (settings.pass()) {
    polnet.call("GET", "/v1/me").then((r) => {
      if (r.status === 200 && r.pass) settings.setPass(r.pass, { handle: r.member.handle, id: r.member.id, role: r.member.role });
      else if (r.status === 401) settings.setPass(null);
      pushAll();
    }).catch(() => undefined);
  }
  createWindow({ url: process.env.POLNET_START_URL });
  app.on("activate", () => { if (windows.size === 0) createWindow(); });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

// For the end-to-end test only (POLNET_E2E=1): a way to see inside without touching the UI.
if (process.env.POLNET_E2E === "1") {
  global.__polnet = { windows, settings: () => settings, stateOf, activeTab, createTab, createWindow, navigate, acceptPass };
}
