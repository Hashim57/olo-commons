"use strict";
/**
 * Everything POL Net remembers, on this computer only, in the app's data folder. The member pass is
 * encrypted with the operating system's keychain (Electron safeStorage) when it is available. Nothing
 * here is ever sent anywhere: there is no telemetry and no sync.
 */
const fs = require("node:fs");
const path = require("node:path");

const DEFAULTS = {
  server: "https://polnet.heliusnetwork.app",
  olo: "https://helius-olo.io",
  search: "duckduckgo",
  shields: true,
  siteShields: {},
  httpsOnly: true,
  history: true,
  oloPrivate: true,
  oloIncludePage: true,
  permissions: {},
  safetyList: true,
};
const HISTORY_MAX = 5000;

class Settings {
  constructor(dir, safeStorage = null) {
    this.dir = dir;
    this.safe = safeStorage;
    this.file = path.join(dir, "settings.json");
    this.historyFile = path.join(dir, "history.json");
    fs.mkdirSync(dir, { recursive: true });
    this.data = { ...DEFAULTS, ...this.read(this.file, {}) };
    this.historyRows = this.read(this.historyFile, []);
  }

  read(file, fallback) {
    try {
      return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
      return fallback;
    }
  }

  write(file, value) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
    fs.renameSync(tmp, file);
  }

  get() {
    const { pass: _pass, oloToken: _olo, ...rest } = this.data;
    return { ...rest, member: this.data.member ?? null };
  }

  set(patch) {
    const allowed = ["server", "olo", "search", "shields", "httpsOnly", "history", "oloPrivate", "oloIncludePage", "safetyList"];
    for (const k of allowed) if (k in patch) this.data[k] = patch[k];
    if (typeof this.data.server === "string") this.data.server = this.data.server.replace(/\/+$/, "");
    if (typeof this.data.olo === "string") this.data.olo = this.data.olo.replace(/\/+$/, "");
    this.write(this.file, this.data);
    return this.get();
  }

  secret(name) {
    const v = this.data[name];
    if (!v) return null;
    if (v.enc && this.safe?.isEncryptionAvailable()) {
      try {
        return this.safe.decryptString(Buffer.from(v.enc, "base64"));
      } catch {
        return null;
      }
    }
    return v.plain ?? null;
  }

  setSecret(name, value) {
    if (!value) delete this.data[name];
    else if (this.safe?.isEncryptionAvailable()) this.data[name] = { enc: this.safe.encryptString(value).toString("base64") };
    else this.data[name] = { plain: value };
    this.write(this.file, this.data);
  }

  pass() { return this.secret("pass"); }
  setPass(pass, member = null) {
    this.setSecret("pass", pass);
    this.data.member = pass ? member : null;
    this.write(this.file, this.data);
  }
  oloToken() { return this.secret("oloToken"); }
  setOloToken(t) { this.setSecret("oloToken", t); }

  siteShieldsOn(host) {
    return this.data.shields !== false && this.data.siteShields[host] !== false;
  }
  setSiteShields(host, on) {
    if (on) delete this.data.siteShields[host];
    else this.data.siteShields[host] = false;
    this.write(this.file, this.data);
  }

  permission(origin, perm) { return this.data.permissions[origin]?.[perm] ?? null; }
  setPermission(origin, perm, value) {
    this.data.permissions[origin] = { ...(this.data.permissions[origin] ?? {}), [perm]: value };
    this.write(this.file, this.data);
  }

  addHistory(url, title) {
    if (!this.data.history || !/^https?:|^pol:/.test(url)) return;
    const last = this.historyRows[this.historyRows.length - 1];
    if (last && last.url === url) {
      last.title = title || last.title;
    } else {
      this.historyRows.push({ url, title: title || url, at: new Date().toISOString() });
      if (this.historyRows.length > HISTORY_MAX) this.historyRows.splice(0, this.historyRows.length - HISTORY_MAX);
    }
    this.write(this.historyFile, this.historyRows);
  }
  history(query = "", limit = 200) {
    const q = String(query).toLowerCase();
    return this.historyRows.filter((r) => !q || r.url.toLowerCase().includes(q) || r.title.toLowerCase().includes(q)).slice(-limit).reverse();
  }
  clearHistory() {
    this.historyRows = [];
    this.write(this.historyFile, this.historyRows);
  }
}

module.exports = { Settings, DEFAULTS };
