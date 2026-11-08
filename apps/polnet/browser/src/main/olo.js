"use strict";
/**
 * Olo inside POL Net: ask about anything, or about the page you are on, and get an answer whose
 * sentences Zeus checks against sources. Talks to helius-olo.io's public stream (the same one the Olo
 * apps use). Private by default: the question is sent with `private: true`, so helius-olo.io does not
 * store the conversation or add it to the Olo brain. The page is attached only when the person leaves
 * "Include this page" ticked, and only its visible text, cut to 12,000 characters.
 */

const PAGE_CHARS = 12_000;

function questionWithPage(question, page) {
  if (!page || !page.text) return question;
  const text = String(page.text).replace(/\s+\n/g, "\n").slice(0, PAGE_CHARS);
  return `${question}\n\n--- Attached: the web page I am reading ---\nTitle: ${page.title || ""}\nAddress: ${page.url || ""}\n\n${text}`;
}

/** Splits a growing NDJSON buffer into complete events and the unfinished rest. */
function ndjson(buffer) {
  const lines = buffer.split("\n");
  const rest = lines.pop() ?? "";
  const events = [];
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    try {
      events.push(JSON.parse(t));
    } catch {
      /* a broken line is skipped, never shown */
    }
  }
  return { events, rest };
}

class Olo {
  constructor({ base, token, setToken, fetch: f }) {
    this.base = base;
    this.token = token;
    this.setToken = setToken;
    this.f = f;
  }

  async session() {
    const have = this.token();
    if (have) return have;
    const r = await this.f(`${this.base()}/api/trpc/auth.createSession`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ json: {} }) });
    if (!r.ok) throw new Error(`Olo could not start a session (${r.status}).`);
    const j = await r.json();
    const token = j?.result?.data?.json?.token;
    if (!token) throw new Error("Olo did not return a session.");
    this.setToken(token);
    return token;
  }

  /** Streams an answer: onEvent gets {type:"delta", text} and the rest of Olo's events. Resolves with the full text. */
  async ask({ question, page, privateChat = true, conversationId }, onEvent, signal) {
    const token = await this.session();
    const r = await this.f(`${this.base()}/api/chat/stream`, {
      method: "POST",
      signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ content: questionWithPage(question, page), private: privateChat, ...(conversationId ? { conversationId } : {}) }),
    });
    if (r.status === 401) {
      this.setToken(null);
      throw new Error("Your Olo session ended. Ask again to start a new one.");
    }
    if (!r.ok || !r.body) {
      let message = `Olo is not answering right now (${r.status}).`;
      try {
        const j = await r.json();
        if (j.message) message = j.message;
      } catch { /* not json */ }
      throw new Error(message);
    }
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let full = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const { events, rest } = ndjson(buf);
      buf = rest;
      for (const e of events) {
        if (e.type === "delta" && typeof e.text === "string") full += e.text;
        if (e.type === "error") throw new Error(e.message || "Olo could not answer that.");
        onEvent(e);
      }
    }
    for (const e of ndjson(`${buf}\n`).events) onEvent(e);
    return full;
  }
}

module.exports = { Olo, questionWithPage, ndjson, PAGE_CHARS };
