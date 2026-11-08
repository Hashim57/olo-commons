"use strict";
// The toolbar's bridge to the main process. Only the browser's own toolbar page loads this.
const { contextBridge, ipcRenderer } = require("electron");

const send = (ch) => (...a) => ipcRenderer.send(ch, ...a);
contextBridge.exposeInMainWorld("browser", {
  newTab: send("ui:new-tab"),
  closeTab: send("ui:close-tab"),
  activate: send("ui:activate"),
  navigate: send("ui:navigate"),
  back: send("ui:back"),
  forward: send("ui:forward"),
  reload: send("ui:reload"),
  stop: send("ui:stop"),
  panel: send("ui:panel"),
  privateWindow: send("ui:private-window"),
  join: send("ui:join"),
  signOut: send("ui:sign-out"),
  toggleShields: send("ui:toggle-shields"),
  state: () => ipcRenderer.invoke("ui:state"),
  overlay: (open) => ipcRenderer.invoke("ui:overlay", open),
  reportSite: (reason) => ipcRenderer.invoke("ui:report-site", reason),
  oloAsk: (req) => ipcRenderer.invoke("ui:olo-ask", req),
  oloStop: send("ui:olo-stop"),
  on: (channel, fn) => {
    if (!["state", "olo-event", "olo-prefill", "olo-check", "focus-address", "report-site"].includes(channel)) return;
    ipcRenderer.on(channel, (_e, data) => fn(data));
  },
});
