"use strict";
// The join window's bridge: hands the member pass back to the browser, and only from the POL Net
// server's own join page (the origin is fixed when the window opens; the main process checks again).
const { contextBridge, ipcRenderer } = require("electron");

const arg = process.argv.find((a) => a.startsWith("--polnet-server="));
const server = arg ? arg.slice("--polnet-server=".length) : "";
if (server && location.origin === server) {
  contextBridge.exposeInMainWorld("polnetBrowser", {
    complete: (pass) => ipcRenderer.invoke("join:complete", String(pass)),
  });
}
