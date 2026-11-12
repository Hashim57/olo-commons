// The WEBOCTA services catalogue: what is free, what is paid, and what is not built yet, in one place
// that the browser's Services page and any website can read (GET /v1/services, public).
//
// Rules for editing it:
// - "live" means a person can use it today. "soon" means it is built and waiting on a review or a
//   deploy. "planned" means it is not built: say so, and never show a price for it.
// - A price appears only when it is the real, current price. Otherwise the note says where to look.
// - Free things come first. The paid things pay for the free ones; no service here is paid for with
//   advertising, tracking or the sale of data.

export type ServiceKind = "free" | "paid";
export type ServiceStatus = "live" | "soon" | "planned";
export type ServiceGroup = "browse" | "know" | "community" | "connect" | "trust" | "build";

export type Service = {
  key: string;
  name: string;
  group: ServiceGroup;
  kind: ServiceKind;
  status: ServiceStatus;
  summary: string;
  /** What it costs, in words. Free services say what is free; paid ones give the price or where it is published. */
  price: string;
  url: string | null;
};

export type ServiceOptions = {
  feeBps: number;
  /** The address of the eSIM store once a supplier account exists; until then eSIMs are "planned". */
  esimStoreUrl?: string;
  /** True once the Square is open to members (it needs the risk assessments in docs/WEBOCTA_SERVICES.md first). */
  squareOpen: boolean;
};

export const GROUPS: Record<ServiceGroup, string> = {
  browse: "Browse privately",
  know: "Know what is true",
  community: "Meet and make",
  connect: "Get connected",
  trust: "Trust tools for websites and organisations",
  build: "Work with Helius",
};

export function services(o: ServiceOptions): Service[] {
  const fee = `${(o.feeBps / 100).toFixed(o.feeBps % 100 === 0 ? 0 : 1)}%`;
  return [
    { key: "polnet", name: "POL Net browser", group: "browse", kind: "free", status: "live", summary: "A private browser for real people: trackers blocked, warnings before scams, no telemetry.", price: "Free. Open source.", url: "https://helius-olo.io/#polnet" },
    { key: "members", name: "Members' network (pol://)", group: "browse", kind: "free", status: "live", summary: "Sites only verified people can open. One person, one account, a different id on every site.", price: "Free for members, including up to five pol:// names.", url: null },
    { key: "family", name: "Protected mode and Family help", group: "browse", kind: "free", status: "live", summary: "A pause at the moments scammers rush people, and a trusted helper who hears when POL Net had to warn.", price: "Free.", url: null },

    { key: "olo", name: "Olo", group: "know", kind: "free", status: "live", summary: "An assistant that answers from sources you can open, with every sentence checked by Zeus.", price: "Free messages every day, without an account.", url: "https://helius-olo.io" },
    { key: "olo-plans", name: "Olo plans", group: "know", kind: "paid", status: "live", summary: "More use, projects, memory and builds, on the web, Mac and iPhone under one account.", price: "Monthly plans, shown at helius-olo.io before you pay.", url: "https://helius-olo.io" },
    { key: "commons", name: "Olo Commons and Zeus", group: "know", kind: "free", status: "live", summary: "The open knowledge base and the open claim verifier behind Olo: data, code and scores in public.", price: "Free. Open data and open source.", url: "https://heliusnetwork.app/olo" },

    { key: "square", name: "The Square", group: "community", kind: "free", status: o.squareOpen ? "live" : "soon", summary: "The members' community for innovation and impact: ideas, projects, questions and research from real people, one vote each.", price: "Free for members.", url: null },
    { key: "heliustv", name: "HeliusTV", group: "community", kind: "free", status: o.squareOpen ? "live" : "soon", summary: "Videos from creators, innovators and people doing impact work, shared and voted on by members. No advertising, no autoplay feed.", price: "Free to watch and to share.", url: null },
    { key: "tasks", name: "Tasks that pay", group: "community", kind: "free", status: "live", summary: "Real work for organisations that help people and places. Members are paid in pounds or euros.", price: "Free for members; nothing is taken from what you earn.", url: null },
    { key: "task-posting", name: "Post tasks to verified people", group: "community", kind: "paid", status: "live", summary: "Organisations fund work with a public benefit and review the evidence members send.", price: `The rewards you set, plus a ${fee} platform fee shown before you pay.`, url: null },

    { key: "esim", name: "Travel and data eSIMs", group: "connect", kind: "paid", status: o.esimStoreUrl ? "live" : "planned", summary: "Mobile data for a trip or a month, installed on your phone in a minute, with no contract.", price: o.esimStoreUrl ? "Pay as you go; each plan's price is shown in the store." : "Not on sale yet.", url: o.esimStoreUrl ?? null },
    { key: "vpn", name: "Private connection (VPN)", group: "connect", kind: "paid", status: "planned", summary: "An encrypted connection from any network, run by Helius, with no activity logs.", price: "Not on sale yet.", url: null },
    { key: "desktop", name: "Cloud desktop", group: "connect", kind: "paid", status: "planned", summary: "A private computer in the cloud you can reach from any device.", price: "Not on sale yet.", url: null },
    { key: "numbers", name: "Virtual phone numbers", group: "connect", kind: "paid", status: "planned", summary: "A second number for calls and texts over data.", price: "Not on sale yet.", url: null },

    { key: "pass", name: "Proof-of-Life Pass", group: "trust", kind: "free", status: "soon", summary: "Prove you are a real person with three moves of your phone. No camera, no face scan, no documents.", price: "Free.", url: "https://heliusnetwork.app/proof-of-life/pass/" },
    { key: "human", name: "\"A real person\" for any website", group: "trust", kind: "free", status: "live", summary: "One link and one file of code tell your site a real person is there, and nothing else about them.", price: "Free for websites to accept POL Net members.", url: "https://github.com/Hashim57/olo-commons/blob/main/docs/TRUST_TOOLS.md" },
    { key: "pol-api", name: "Proof-of-Life for businesses", group: "trust", kind: "paid", status: "live", summary: "Stop bots, duplicate accounts and reward abuse at sign-up, without collecting identity documents.", price: "Plans at heliusnetwork.app/proof-of-life. Design partners use the Growth plan free for 60 days.", url: "https://heliusnetwork.app/proof-of-life" },

    { key: "security-check", name: "AI-Built App Security Check", group: "build", kind: "paid", status: "live", summary: "A written report within 72 hours on the security of an app built with AI tools, with the exact fix for every finding.", price: "US$595, fixed.", url: "https://buy.stripe.com/14A8wRdo95I12VVffB8EM00" },
    { key: "code-review", name: "Secure Code and API Review", group: "build", kind: "paid", status: "live", summary: "A senior review of your code, API and data rules before launch or audit.", price: "From £1,200.", url: "https://hashimruan.com/#book" },
  ];
}
