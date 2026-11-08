"use strict";
// Loaded in every tab, but the bridge exists only on the browser's own polnet:// pages. Ordinary web
// pages get nothing: no new globals, no way to reach the main process. The main process checks the
// sender's address again on every call.
const { contextBridge, ipcRenderer } = require("electron");

if (location.protocol === "polnet:") {
  contextBridge.exposeInMainWorld("polnet", {
    status: () => ipcRenderer.invoke("page:status"),
    config: () => ipcRenderer.invoke("page:config"),
    api: (method, path, body) => ipcRenderer.invoke("page:api", { method, path, body }),
    join: () => ipcRenderer.send("page:join"),
    open: (url) => ipcRenderer.send("page:open", url),
    settings: (patch) => ipcRenderer.invoke("page:settings", patch),
    history: (opts) => ipcRenderer.invoke("page:history", opts),
    clearData: () => ipcRenderer.invoke("page:clear-data"),
    proceed: (url, kind) => ipcRenderer.send("page:proceed", { url, kind }),
    humanCheck: (query) => ipcRenderer.invoke("page:human-check", query),
    human: (query) => ipcRenderer.invoke("page:human", query),
  });
}
