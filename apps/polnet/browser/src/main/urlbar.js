"use strict";
/** What the address bar does with what is typed: an address, a pol:// member site, or a private search. */

const ENGINES = {
  duckduckgo: { name: "DuckDuckGo", url: "https://duckduckgo.com/?q=%s" },
  brave: { name: "Brave Search", url: "https://search.brave.com/search?q=%s" },
  startpage: { name: "Startpage", url: "https://www.startpage.com/do/search?q=%s" },
  mojeek: { name: "Mojeek", url: "https://www.mojeek.com/search?q=%s" },
  olo: { name: "Olo (answers checked by Zeus)", url: "https://helius-olo.io/?q=%s" },
};

function toUrl(input, engine = "duckduckgo") {
  const text = String(input || "").trim();
  if (!text) return null;
  if (/^(pol|polnet):\/\//i.test(text)) return text.replace(/^POL:/i, "pol:").replace(/^POLNET:/i, "polnet:");
  if (/^https?:\/\//i.test(text)) return text;
  if (/^(about:blank|file:\/\/)/i.test(text)) return text.startsWith("file:") ? null : text;
  if (/^(javascript|data|vbscript):/i.test(text)) return null;
  if (/^localhost(:\d+)?(\/|$)/i.test(text) || /^\d+\.\d+\.\d+\.\d+(:\d+)?(\/|$)/.test(text)) return `http://${text}`;
  if (!/\s/.test(text) && /^[^/?#]+\.[a-z]{2,}(:\d+)?([/?#].*)?$/i.test(text)) return `https://${text}`;
  const e = ENGINES[engine] || ENGINES.duckduckgo;
  return e.url.replace("%s", encodeURIComponent(text));
}

module.exports = { ENGINES, toUrl };
