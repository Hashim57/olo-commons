// What POL Net keeps, behind one interface: MemoryStore for tests and local runs, PgStore (store_pg.ts)
// for the Supabase database. Operations that must not race (claiming a slot, approving a claim and
// crediting the member, paying out) are single methods, so the Postgres store can run each in one
// transaction with row locks.
//
// Privacy: a member is a Proof-of-Life subject (pairwise to POL Net, so it links to nothing else) and a
// handle the member chooses. No email, no name, no phone number, no IP address is stored. Payout
// identity checks are Stripe's, on Stripe's side; POL Net keeps only the connected account id.

export type Role = "member" | "poster";

export type Member = {
  id: string;
  subject: string;
  handle: string;
  role: Role;
  suspended: boolean;
  stripe_account: string | null;
  payouts_enabled: boolean;
  created_at: string;
};

export type PolName = {
  name: string;
  owner: string;
  target: string;
  description: string;
  suspended: boolean;
  created_at: string;
};

export type TaskStatus = "draft" | "open" | "closed";

export type Task = {
  id: string;
  poster: string;
  title: string;
  description: string;
  instructions: string;
  category: string;
  reward_pence: number;
  currency: "GBP" | "EUR";
  slots: number;
  status: TaskStatus;
  deadline: string | null;
  fee_pence: number;
  funded_pence: number;
  created_at: string;
};

export type ClaimStatus = "claimed" | "submitted" | "approved" | "rejected";

export type Claim = {
  id: string;
  task_id: string;
  member_id: string;
  status: ClaimStatus;
  evidence_text: string | null;
  evidence_url: string | null;
  note: string | null;
  created_at: string;
  submitted_at: string | null;
  reviewed_at: string | null;
};

export type LedgerKind = "task_reward" | "payout" | "payout_reversal";

export type LedgerEntry = {
  id: string;
  member_id: string;
  amount_pence: number;
  currency: "GBP" | "EUR";
  kind: LedgerKind;
  ref: string;
  created_at: string;
};

export type ReportKind = "name" | "task" | "member" | "site" | "post";

/** A post in the Square, the members' community. `link` is an https address (required for HeliusTV posts). */
export type Post = { id: string; author: string; topic: string; title: string; body: string; link: string | null; removed: boolean; created_at: string };

export type PostRow = Post & { votes: number; comments: number };

export type Comment = { id: string; post_id: string; author: string; body: string; created_at: string };

export type HelperLink = { id: string; protected_id: string; helper_id: string; created_at: string };

export type AlertKind = "lookalike" | "reported" | "scam-page" | "remote-access" | "pause" | "download";

export type HelperAlert = { id: string; protected_id: string; host: string; kind: AlertKind; created_at: string };

export type ClaimError = "task_not_found" | "task_not_open" | "already_claimed" | "no_slots" | "own_task" | "past_deadline";

export interface Store {
  memberBySubject(subject: string): Promise<Member | null>;
  memberById(id: string): Promise<Member | null>;
  memberByHandle(handle: string): Promise<Member | null>;
  createMember(m: Omit<Member, "created_at">): Promise<Member>;
  updateMember(id: string, patch: Partial<Pick<Member, "role" | "suspended" | "stripe_account" | "payouts_enabled" | "handle">>): Promise<Member | null>;

  nameGet(name: string): Promise<PolName | null>;
  /** False when the name is taken. */
  nameCreate(n: Omit<PolName, "created_at" | "suspended">): Promise<boolean>;
  namesByOwner(owner: string): Promise<PolName[]>;
  nameDelete(owner: string, name: string): Promise<boolean>;
  nameSetSuspended(name: string, suspended: boolean): Promise<void>;

  taskCreate(t: Omit<Task, "created_at">): Promise<Task>;
  taskGet(id: string): Promise<Task | null>;
  tasks(filter: { status?: TaskStatus; poster?: string; limit?: number }): Promise<Task[]>;
  taskUpdate(id: string, patch: Partial<Pick<Task, "status" | "funded_pence">>): Promise<Task | null>;
  /** Claims still holding a slot (anything but rejected). */
  taskSlotsTaken(taskId: string): Promise<number>;

  /**
   * Claims a slot. Claims left unsubmitted since before `staleBefore` are expired first (rejected with the
   * note "expired"), so nobody can sit on slots.
   */
  claimCreate(taskId: string, memberId: string, id: string, now: string, staleBefore: string): Promise<{ claim?: Claim; error?: ClaimError }>;
  claimGet(id: string): Promise<Claim | null>;
  claimsByMember(memberId: string): Promise<Claim[]>;
  claimsByTask(taskId: string): Promise<Claim[]>;
  claimSubmit(id: string, memberId: string, evidence: { text: string | null; url: string | null }, now: string): Promise<Claim | null>;
  /** Approves (crediting the reward to the member's ledger in the same step) or rejects a submitted claim. */
  claimReview(id: string, approve: boolean, note: string | null, now: string, credit: Omit<LedgerEntry, "created_at"> | null): Promise<Claim | null>;

  ledgerAdd(e: Omit<LedgerEntry, "created_at">): Promise<void>;
  ledger(memberId: string, limit?: number): Promise<LedgerEntry[]>;
  balance(memberId: string, currency: "GBP" | "EUR"): Promise<number>;
  /** Debits a payout only if the balance covers it; false otherwise. */
  payoutDebit(e: Omit<LedgerEntry, "created_at">): Promise<boolean>;

  /** One report per reporter per target; returns how many distinct members have reported the target. */
  report(r: { id: string; reporter: string; kind: ReportKind; target: string; reason: string; created_at: string }): Promise<number>;

  /** Targets of one kind reported by at least `min` distinct members (for the community safety list). */
  reportedTargets(kind: ReportKind, min: number): Promise<string[]>;

  /** A one-time invite for a helper, stored by the hash of its code. */
  helperInviteCreate(codeHash: string, memberId: string, expiresAt: string): Promise<void>;
  /** Uses up an invite: the inviting member's id, or null when unknown or expired. */
  helperInviteTake(codeHash: string, now: string): Promise<string | null>;
  /** False when the link exists already or the protected member has `max` helpers. */
  helperLink(link: Omit<HelperLink, "created_at">, max: number): Promise<boolean>;
  helpersOf(protectedId: string): Promise<HelperLink[]>;
  helping(helperId: string): Promise<HelperLink[]>;
  /** Ends a link from either side. */
  helperUnlink(id: string, memberId: string): Promise<boolean>;
  /** Stores an alert and drops this member's alerts older than `pruneBefore`. */
  helperAlertAdd(a: Omit<HelperAlert, "created_at">, now: string, pruneBefore: string): Promise<void>;
  /** Alerts from everyone this helper helps, newest first, since `since`. */
  helperAlertsFor(helperId: string, since: string, limit: number): Promise<HelperAlert[]>;

  postCreate(p: Omit<Post, "created_at" | "removed">, now: string): Promise<Post>;
  postGet(id: string): Promise<PostRow | null>;
  /** Posts that have not been removed: newest first, or most voted first (ties broken by newest). */
  posts(filter: { topic?: string; sort: "new" | "top"; limit: number }): Promise<PostRow[]>;
  postSetRemoved(id: string, removed: boolean): Promise<boolean>;
  /** The author deletes their own post; comments and votes go with it. */
  postDelete(id: string, author: string): Promise<boolean>;
  /** One vote per member per post (one real person, one vote). Returns the post's vote count. */
  voteSet(postId: string, memberId: string, on: boolean): Promise<number>;
  /** Which of these posts the member has voted for. */
  voted(memberId: string, postIds: string[]): Promise<string[]>;
  /** Null when the post does not exist or has been removed. */
  commentCreate(c: Omit<Comment, "created_at">, now: string): Promise<Comment | null>;
  comments(postId: string, limit: number): Promise<Comment[]>;
  commentDelete(id: string, author: string): Promise<boolean>;

  /** Counts a hit; true while under the limit for the window. */
  hit(key: string, windowMs: number, limit: number, nowMs: number): Promise<boolean>;
}

export class MemoryStore implements Store {
  members = new Map<string, Member>();
  names = new Map<string, PolName>();
  taskRows = new Map<string, Task>();
  claims = new Map<string, Claim>();
  entries: LedgerEntry[] = [];
  reports: Array<{ id: string; reporter: string; kind: ReportKind; target: string; reason: string; created_at: string }> = [];
  hits = new Map<string, number[]>();
  invites = new Map<string, { member_id: string; expires_at: string }>();
  links: HelperLink[] = [];
  alerts: HelperAlert[] = [];
  postRows = new Map<string, Post>();
  commentRows = new Map<string, Comment>();
  votes = new Set<string>();
  private now = () => new Date().toISOString();

  async memberBySubject(subject: string) { return [...this.members.values()].find((m) => m.subject === subject) ?? null; }
  async memberById(id: string) { return this.members.get(id) ?? null; }
  async memberByHandle(handle: string) { return [...this.members.values()].find((m) => m.handle.toLowerCase() === handle.toLowerCase()) ?? null; }
  async createMember(m: Omit<Member, "created_at">) {
    const row = { ...m, created_at: this.now() };
    this.members.set(m.id, row);
    return row;
  }
  async updateMember(id: string, patch: Partial<Member>) {
    const m = this.members.get(id);
    if (!m) return null;
    Object.assign(m, patch);
    return m;
  }

  async nameGet(name: string) { return this.names.get(name) ?? null; }
  async nameCreate(n: Omit<PolName, "created_at" | "suspended">) {
    if (this.names.has(n.name)) return false;
    this.names.set(n.name, { ...n, suspended: false, created_at: this.now() });
    return true;
  }
  async namesByOwner(owner: string) { return [...this.names.values()].filter((n) => n.owner === owner); }
  async nameDelete(owner: string, name: string) {
    const n = this.names.get(name);
    if (!n || n.owner !== owner) return false;
    this.names.delete(name);
    return true;
  }
  async nameSetSuspended(name: string, suspended: boolean) {
    const n = this.names.get(name);
    if (n) n.suspended = suspended;
  }

  async taskCreate(t: Omit<Task, "created_at">) {
    const row = { ...t, created_at: this.now() };
    this.taskRows.set(t.id, row);
    return row;
  }
  async taskGet(id: string) { return this.taskRows.get(id) ?? null; }
  async tasks(f: { status?: TaskStatus; poster?: string; limit?: number }) {
    return [...this.taskRows.values()]
      .filter((t) => (!f.status || t.status === f.status) && (!f.poster || t.poster === f.poster))
      .sort((a, b) => b.created_at.localeCompare(a.created_at))
      .slice(0, f.limit ?? 100);
  }
  async taskUpdate(id: string, patch: Partial<Task>) {
    const t = this.taskRows.get(id);
    if (!t) return null;
    Object.assign(t, patch);
    return t;
  }
  async taskSlotsTaken(taskId: string) { return [...this.claims.values()].filter((c) => c.task_id === taskId && c.status !== "rejected").length; }

  async claimCreate(taskId: string, memberId: string, id: string, now: string, staleBefore: string) {
    for (const c of this.claims.values()) {
      if (c.task_id === taskId && c.status === "claimed" && c.created_at < staleBefore) Object.assign(c, { status: "rejected", note: "expired", reviewed_at: now });
    }
    const t = this.taskRows.get(taskId);
    if (!t) return { error: "task_not_found" as const };
    if (t.status !== "open") return { error: "task_not_open" as const };
    if (t.poster === memberId) return { error: "own_task" as const };
    if (t.deadline && t.deadline < now) return { error: "past_deadline" as const };
    if ([...this.claims.values()].some((c) => c.task_id === taskId && c.member_id === memberId && c.note !== "expired")) return { error: "already_claimed" as const };
    // Counted without an await between the check and the insert, so parallel claims cannot overfill a task.
    if ([...this.claims.values()].filter((c) => c.task_id === taskId && c.status !== "rejected").length >= t.slots) return { error: "no_slots" as const };
    const claim: Claim = { id, task_id: taskId, member_id: memberId, status: "claimed", evidence_text: null, evidence_url: null, note: null, created_at: now, submitted_at: null, reviewed_at: null };
    this.claims.set(id, claim);
    return { claim };
  }
  async claimGet(id: string) { return this.claims.get(id) ?? null; }
  async claimsByMember(memberId: string) { return [...this.claims.values()].filter((c) => c.member_id === memberId).sort((a, b) => b.created_at.localeCompare(a.created_at)); }
  async claimsByTask(taskId: string) { return [...this.claims.values()].filter((c) => c.task_id === taskId).sort((a, b) => a.created_at.localeCompare(b.created_at)); }
  async claimSubmit(id: string, memberId: string, ev: { text: string | null; url: string | null }, now: string) {
    const c = this.claims.get(id);
    if (!c || c.member_id !== memberId || (c.status !== "claimed" && c.status !== "submitted")) return null;
    Object.assign(c, { status: "submitted", evidence_text: ev.text, evidence_url: ev.url, submitted_at: now });
    return c;
  }
  async claimReview(id: string, approve: boolean, note: string | null, now: string, credit: Omit<LedgerEntry, "created_at"> | null) {
    const c = this.claims.get(id);
    if (!c || c.status !== "submitted") return null;
    Object.assign(c, { status: approve ? "approved" : "rejected", note, reviewed_at: now });
    if (approve && credit) this.entries.push({ ...credit, created_at: now });
    return c;
  }

  async ledgerAdd(e: Omit<LedgerEntry, "created_at">) { this.entries.push({ ...e, created_at: this.now() }); }
  async ledger(memberId: string, limit = 100) {
    return this.entries.filter((e) => e.member_id === memberId).sort((a, b) => b.created_at.localeCompare(a.created_at)).slice(0, limit);
  }
  async balance(memberId: string, currency: "GBP" | "EUR") {
    return this.entries.filter((e) => e.member_id === memberId && e.currency === currency).reduce((s, e) => s + e.amount_pence, 0);
  }
  async payoutDebit(e: Omit<LedgerEntry, "created_at">) {
    if ((await this.balance(e.member_id, e.currency)) + e.amount_pence < 0) return false;
    this.entries.push({ ...e, created_at: this.now() });
    return true;
  }

  async report(r: { id: string; reporter: string; kind: ReportKind; target: string; reason: string; created_at: string }) {
    if (!this.reports.some((x) => x.reporter === r.reporter && x.kind === r.kind && x.target === r.target)) this.reports.push(r);
    return new Set(this.reports.filter((x) => x.kind === r.kind && x.target === r.target).map((x) => x.reporter)).size;
  }

  async reportedTargets(kind: ReportKind, min: number) {
    const by = new Map<string, Set<string>>();
    for (const r of this.reports) if (r.kind === kind) by.set(r.target, (by.get(r.target) ?? new Set()).add(r.reporter));
    return [...by].filter(([, who]) => who.size >= min).map(([t]) => t);
  }

  async helperInviteCreate(codeHash: string, memberId: string, expiresAt: string) { this.invites.set(codeHash, { member_id: memberId, expires_at: expiresAt }); }
  async helperInviteTake(codeHash: string, now: string) {
    const i = this.invites.get(codeHash);
    this.invites.delete(codeHash);
    return i && i.expires_at > now ? i.member_id : null;
  }
  async helperLink(l: Omit<HelperLink, "created_at">, max: number) {
    const mine = this.links.filter((x) => x.protected_id === l.protected_id);
    if (mine.length >= max || mine.some((x) => x.helper_id === l.helper_id) || l.protected_id === l.helper_id) return false;
    this.links.push({ ...l, created_at: this.now() });
    return true;
  }
  async helpersOf(protectedId: string) { return this.links.filter((x) => x.protected_id === protectedId); }
  async helping(helperId: string) { return this.links.filter((x) => x.helper_id === helperId); }
  async helperUnlink(id: string, memberId: string) {
    const i = this.links.findIndex((x) => x.id === id && (x.protected_id === memberId || x.helper_id === memberId));
    if (i < 0) return false;
    this.links.splice(i, 1);
    return true;
  }
  async helperAlertAdd(a: Omit<HelperAlert, "created_at">, now: string, pruneBefore: string) {
    this.alerts = this.alerts.filter((x) => !(x.protected_id === a.protected_id && x.created_at < pruneBefore));
    this.alerts.push({ ...a, created_at: now });
  }
  async helperAlertsFor(helperId: string, since: string, limit: number) {
    const who = new Set(this.links.filter((x) => x.helper_id === helperId).map((x) => x.protected_id));
    return this.alerts.filter((a) => who.has(a.protected_id) && a.created_at >= since).sort((a, b) => b.created_at.localeCompare(a.created_at)).slice(0, limit);
  }

  private row(p: Post): PostRow {
    return { ...p, votes: [...this.votes].filter((v) => v.startsWith(`${p.id}:`)).length, comments: [...this.commentRows.values()].filter((c) => c.post_id === p.id).length };
  }
  async postCreate(p: Omit<Post, "created_at" | "removed">, now: string) {
    const row = { ...p, removed: false, created_at: now };
    this.postRows.set(p.id, row);
    return row;
  }
  async postGet(id: string) { const p = this.postRows.get(id); return p ? this.row(p) : null; }
  async posts(f: { topic?: string; sort: "new" | "top"; limit: number }) {
    const rows = [...this.postRows.values()].filter((p) => !p.removed && (!f.topic || p.topic === f.topic)).map((p) => this.row(p));
    rows.sort((a, b) => (f.sort === "top" ? b.votes - a.votes : 0) || b.created_at.localeCompare(a.created_at) || b.id.localeCompare(a.id));
    return rows.slice(0, f.limit);
  }
  async postSetRemoved(id: string, removed: boolean) {
    const p = this.postRows.get(id);
    if (!p) return false;
    p.removed = removed;
    return true;
  }
  async postDelete(id: string, author: string) {
    const p = this.postRows.get(id);
    if (!p || p.author !== author) return false;
    this.postRows.delete(id);
    for (const [cid, c] of this.commentRows) if (c.post_id === id) this.commentRows.delete(cid);
    for (const v of this.votes) if (v.startsWith(`${id}:`)) this.votes.delete(v);
    return true;
  }
  async voteSet(postId: string, memberId: string, on: boolean) {
    const p = this.postRows.get(postId);
    if (p && !p.removed) {
      if (on) this.votes.add(`${postId}:${memberId}`);
      else this.votes.delete(`${postId}:${memberId}`);
    }
    return [...this.votes].filter((v) => v.startsWith(`${postId}:`)).length;
  }
  async voted(memberId: string, postIds: string[]) { return postIds.filter((id) => this.votes.has(`${id}:${memberId}`)); }
  async commentCreate(c: Omit<Comment, "created_at">, now: string) {
    const p = this.postRows.get(c.post_id);
    if (!p || p.removed) return null;
    const row = { ...c, created_at: now };
    this.commentRows.set(c.id, row);
    return row;
  }
  async comments(postId: string, limit: number) {
    return [...this.commentRows.values()].filter((c) => c.post_id === postId).sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id)).slice(0, limit);
  }
  async commentDelete(id: string, author: string) {
    const c = this.commentRows.get(id);
    if (!c || c.author !== author) return false;
    this.commentRows.delete(id);
    return true;
  }

  async hit(key: string, windowMs: number, limit: number, nowMs: number) {
    const list = (this.hits.get(key) ?? []).filter((t) => nowMs - t < windowMs);
    if (list.length >= limit) {
      this.hits.set(key, list);
      return false;
    }
    list.push(nowMs);
    this.hits.set(key, list);
    return true;
  }
}
