// deno-lint-ignore-file no-explicit-any
// The Store over Postgres (the polnet schema, sql in ../../migrations/001_polnet.sql). Uses the postgres
// driver because the Edge Function connects with SUPABASE_DB_URL as the owner; the schema grants nothing
// to anon or authenticated. Racy operations run in one transaction with row locks.

import postgres from "npm:postgres@3.4.5";
import type { Claim, ClaimError, Comment, HelperAlert, HelperLink, LedgerEntry, Member, PolName, Post, PostRow, ReportKind, Store, Task, TaskStatus } from "./store.ts";

type Sql = ReturnType<typeof postgres>;

const ts = (v: unknown): string => (v instanceof Date ? v.toISOString() : String(v));
const tsn = (v: unknown): string | null => (v === null || v === undefined ? null : ts(v));

const member = (r: Record<string, unknown>): Member => ({
  id: String(r.id), subject: String(r.subject), handle: String(r.handle), role: r.role as Member["role"], suspended: Boolean(r.suspended),
  stripe_account: (r.stripe_account as string | null) ?? null, payouts_enabled: Boolean(r.payouts_enabled), created_at: ts(r.created_at),
});
const polName = (r: Record<string, unknown>): PolName => ({
  name: String(r.name), owner: String(r.owner), target: String(r.target), description: String(r.description), suspended: Boolean(r.suspended), created_at: ts(r.created_at),
});
const task = (r: Record<string, unknown>): Task => ({
  id: String(r.id), poster: String(r.poster), title: String(r.title), description: String(r.description), instructions: String(r.instructions),
  category: String(r.category), reward_pence: Number(r.reward_pence), currency: r.currency as Task["currency"], slots: Number(r.slots),
  status: r.status as TaskStatus, deadline: tsn(r.deadline), fee_pence: Number(r.fee_pence), funded_pence: Number(r.funded_pence), created_at: ts(r.created_at),
});
const claim = (r: Record<string, unknown>): Claim => ({
  id: String(r.id), task_id: String(r.task_id), member_id: String(r.member_id), status: r.status as Claim["status"],
  evidence_text: (r.evidence_text as string | null) ?? null, evidence_url: (r.evidence_url as string | null) ?? null, note: (r.note as string | null) ?? null,
  created_at: ts(r.created_at), submitted_at: tsn(r.submitted_at), reviewed_at: tsn(r.reviewed_at),
});
const entry = (r: Record<string, unknown>): LedgerEntry => ({
  id: String(r.id), member_id: String(r.member_id), amount_pence: Number(r.amount_pence), currency: r.currency as LedgerEntry["currency"],
  kind: r.kind as LedgerEntry["kind"], ref: String(r.ref), created_at: ts(r.created_at),
});

const link = (r: Record<string, unknown>): HelperLink => ({ id: String(r.id), protected_id: String(r.protected_id), helper_id: String(r.helper_id), created_at: ts(r.created_at) });
const alert = (r: Record<string, unknown>): HelperAlert => ({ id: String(r.id), protected_id: String(r.protected_id), host: String(r.host), kind: r.kind as HelperAlert["kind"], created_at: ts(r.created_at) });
const post = (r: Record<string, unknown>): PostRow => ({
  id: String(r.id), author: String(r.author), topic: String(r.topic), title: String(r.title), body: String(r.body), link: (r.link as string | null) ?? null,
  removed: Boolean(r.removed), created_at: ts(r.created_at), votes: Number(r.votes ?? 0), comments: Number(r.comments ?? 0),
});
const comment = (r: Record<string, unknown>): Comment => ({ id: String(r.id), post_id: String(r.post_id), author: String(r.author), body: String(r.body), created_at: ts(r.created_at) });
const isId = (v: string) => /^[0-9a-f-]{36}$/i.test(v);

export class PgStore implements Store {
  constructor(private sql: Sql) {}

  static connect(url: string): PgStore {
    return new PgStore(postgres(url, { max: 3, prepare: false, idle_timeout: 20 }));
  }

  async close() { await this.sql.end({ timeout: 5 }); }

  async memberBySubject(subject: string) { const [r] = await this.sql`select * from polnet.members where subject = ${subject}`; return r ? member(r) : null; }
  async memberById(id: string) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const [r] = await this.sql`select * from polnet.members where id = ${id}`;
    return r ? member(r) : null;
  }
  async memberByHandle(handle: string) { const [r] = await this.sql`select * from polnet.members where lower(handle) = lower(${handle})`; return r ? member(r) : null; }
  async createMember(m: Omit<Member, "created_at">) {
    const [r] = await this.sql`insert into polnet.members (id, subject, handle, role, suspended, stripe_account, payouts_enabled)
      values (${m.id}, ${m.subject}, ${m.handle}, ${m.role}, ${m.suspended}, ${m.stripe_account}, ${m.payouts_enabled}) returning *`;
    return member(r);
  }
  async updateMember(id: string, patch: Partial<Pick<Member, "role" | "suspended" | "stripe_account" | "payouts_enabled" | "handle">>) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const cols = Object.keys(patch) as Array<keyof typeof patch>;
    if (cols.length === 0) return this.memberById(id);
    const [r] = await this.sql`update polnet.members set ${this.sql(patch as Record<string, any>, ...(cols as string[]))} where id = ${id} returning *`;
    return r ? member(r) : null;
  }

  async nameGet(name: string) { const [r] = await this.sql`select * from polnet.names where name = ${name}`; return r ? polName(r) : null; }
  async nameCreate(n: Omit<PolName, "created_at" | "suspended">) {
    const rows = await this.sql`insert into polnet.names (name, owner, target, description) values (${n.name}, ${n.owner}, ${n.target}, ${n.description})
      on conflict (name) do nothing returning name`;
    return rows.length === 1;
  }
  async namesByOwner(owner: string) { return (await this.sql`select * from polnet.names where owner = ${owner} order by created_at`).map(polName); }
  async nameDelete(owner: string, name: string) { return (await this.sql`delete from polnet.names where owner = ${owner} and name = ${name} returning name`).length === 1; }
  async nameSetSuspended(name: string, suspended: boolean) { await this.sql`update polnet.names set suspended = ${suspended} where name = ${name}`; }

  async taskCreate(t: Omit<Task, "created_at">) {
    const [r] = await this.sql`insert into polnet.tasks (id, poster, title, description, instructions, category, reward_pence, currency, slots, status, deadline, fee_pence, funded_pence)
      values (${t.id}, ${t.poster}, ${t.title}, ${t.description}, ${t.instructions}, ${t.category}, ${t.reward_pence}, ${t.currency}, ${t.slots}, ${t.status}, ${t.deadline}, ${t.fee_pence}, ${t.funded_pence}) returning *`;
    return task(r);
  }
  async taskGet(id: string) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const [r] = await this.sql`select * from polnet.tasks where id = ${id}`;
    return r ? task(r) : null;
  }
  async tasks(f: { status?: TaskStatus; poster?: string; limit?: number }) {
    const rows = await this.sql`select * from polnet.tasks where (${f.status ?? null}::text is null or status = ${f.status ?? null})
      and (${f.poster ?? null}::uuid is null or poster = ${f.poster ?? null}::uuid) order by created_at desc limit ${f.limit ?? 100}`;
    return rows.map(task);
  }
  async taskUpdate(id: string, patch: Partial<Pick<Task, "status" | "funded_pence">>) {
    const cols = Object.keys(patch) as Array<keyof typeof patch>;
    if (cols.length === 0) return this.taskGet(id);
    const [r] = await this.sql`update polnet.tasks set ${this.sql(patch as Record<string, any>, ...(cols as string[]))} where id = ${id} returning *`;
    return r ? task(r) : null;
  }
  async taskSlotsTaken(taskId: string) {
    const [r] = await this.sql`select count(*)::int as n from polnet.claims where task_id = ${taskId} and status <> 'rejected'`;
    return Number(r.n);
  }

  async claimCreate(taskId: string, memberId: string, id: string, now: string, staleBefore: string): Promise<{ claim?: Claim; error?: ClaimError }> {
    if (!/^[0-9a-f-]{36}$/i.test(taskId)) return { error: "task_not_found" };
    return await this.sql.begin(async (tx) => {
      const [t] = await tx`select * from polnet.tasks where id = ${taskId} for update`;
      if (!t) return { error: "task_not_found" as const };
      await tx`update polnet.claims set status = 'rejected', note = 'expired', reviewed_at = ${now} where task_id = ${taskId} and status = 'claimed' and created_at < ${staleBefore}`;
      const tk = task(t);
      if (tk.status !== "open") return { error: "task_not_open" as const };
      if (tk.poster === memberId) return { error: "own_task" as const };
      if (tk.deadline && tk.deadline < now) return { error: "past_deadline" as const };
      const [mine] = await tx`select 1 from polnet.claims where task_id = ${taskId} and member_id = ${memberId} and coalesce(note, '') <> 'expired'`;
      if (mine) return { error: "already_claimed" as const };
      const [{ n }] = await tx`select count(*)::int as n from polnet.claims where task_id = ${taskId} and status <> 'rejected'`;
      if (Number(n) >= tk.slots) return { error: "no_slots" as const };
      const [r] = await tx`insert into polnet.claims (id, task_id, member_id, created_at) values (${id}, ${taskId}, ${memberId}, ${now}) returning *`;
      return { claim: claim(r) };
    }) as { claim?: Claim; error?: ClaimError };
  }
  async claimGet(id: string) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const [r] = await this.sql`select * from polnet.claims where id = ${id}`;
    return r ? claim(r) : null;
  }
  async claimsByMember(memberId: string) { return (await this.sql`select * from polnet.claims where member_id = ${memberId} order by created_at desc limit 200`).map(claim); }
  async claimsByTask(taskId: string) { return (await this.sql`select * from polnet.claims where task_id = ${taskId} order by created_at`).map(claim); }
  async claimSubmit(id: string, memberId: string, ev: { text: string | null; url: string | null }, now: string) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const [r] = await this.sql`update polnet.claims set status = 'submitted', evidence_text = ${ev.text}, evidence_url = ${ev.url}, submitted_at = ${now}
      where id = ${id} and member_id = ${memberId} and status in ('claimed', 'submitted') returning *`;
    return r ? claim(r) : null;
  }
  async claimReview(id: string, approve: boolean, note: string | null, now: string, credit: Omit<LedgerEntry, "created_at"> | null) {
    return await this.sql.begin(async (tx) => {
      const [r] = await tx`update polnet.claims set status = ${approve ? "approved" : "rejected"}, note = ${note}, reviewed_at = ${now}
        where id = ${id} and status = 'submitted' returning *`;
      if (!r) return null;
      if (approve && credit) {
        await tx`insert into polnet.ledger (id, member_id, amount_pence, currency, kind, ref, created_at)
          values (${credit.id}, ${credit.member_id}, ${credit.amount_pence}, ${credit.currency}, ${credit.kind}, ${credit.ref}, ${now})`;
      }
      return claim(r);
    }) as Claim | null;
  }

  async ledgerAdd(e: Omit<LedgerEntry, "created_at">) {
    await this.sql`insert into polnet.ledger (id, member_id, amount_pence, currency, kind, ref) values (${e.id}, ${e.member_id}, ${e.amount_pence}, ${e.currency}, ${e.kind}, ${e.ref})`;
  }
  async ledger(memberId: string, limit = 100) { return (await this.sql`select * from polnet.ledger where member_id = ${memberId} order by created_at desc limit ${limit}`).map(entry); }
  async balance(memberId: string, currency: "GBP" | "EUR") {
    const [r] = await this.sql`select coalesce(sum(amount_pence), 0)::int as b from polnet.ledger where member_id = ${memberId} and currency = ${currency}`;
    return Number(r.b);
  }
  async payoutDebit(e: Omit<LedgerEntry, "created_at">) {
    return await this.sql.begin(async (tx) => {
      // Serialises payouts per member, so two requests cannot both spend the same balance.
      await tx`select id from polnet.members where id = ${e.member_id} for update`;
      const [r] = await tx`select coalesce(sum(amount_pence), 0)::int as b from polnet.ledger where member_id = ${e.member_id} and currency = ${e.currency}`;
      if (Number(r.b) + e.amount_pence < 0) return false;
      await tx`insert into polnet.ledger (id, member_id, amount_pence, currency, kind, ref) values (${e.id}, ${e.member_id}, ${e.amount_pence}, ${e.currency}, ${e.kind}, ${e.ref})`;
      return true;
    }) as boolean;
  }

  async report(r: { id: string; reporter: string; kind: ReportKind; target: string; reason: string; created_at: string }) {
    await this.sql`insert into polnet.reports (id, reporter, kind, target, reason, created_at) values (${r.id}, ${r.reporter}, ${r.kind}, ${r.target}, ${r.reason}, ${r.created_at})
      on conflict (reporter, kind, target) do nothing`;
    const [c] = await this.sql`select count(distinct reporter)::int as n from polnet.reports where kind = ${r.kind} and target = ${r.target}`;
    return Number(c.n);
  }

  async reportedTargets(kind: ReportKind, min: number) {
    const rows = await this.sql`select target from polnet.reports where kind = ${kind} group by target having count(distinct reporter) >= ${min}`;
    return rows.map((r) => String(r.target));
  }

  async helperInviteCreate(codeHash: string, memberId: string, expiresAt: string) {
    await this.sql`insert into polnet.helper_invites (code_hash, member_id, expires_at) values (${codeHash}, ${memberId}, ${expiresAt})
      on conflict (code_hash) do update set member_id = excluded.member_id, expires_at = excluded.expires_at`;
  }
  async helperInviteTake(codeHash: string, now: string) {
    const [r] = await this.sql`delete from polnet.helper_invites where code_hash = ${codeHash} returning member_id, expires_at`;
    return r && ts(r.expires_at) > now ? String(r.member_id) : null;
  }
  async helperLink(l: Omit<HelperLink, "created_at">, max: number) {
    if (l.protected_id === l.helper_id) return false;
    return await this.sql.begin(async (tx) => {
      // Locks the protected member's row so two accepts cannot pass the limit together.
      await tx`select id from polnet.members where id = ${l.protected_id} for update`;
      const [c] = await tx`select count(*)::int as n from polnet.helpers where protected_id = ${l.protected_id}`;
      if (Number(c.n) >= max) return false;
      const rows = await tx`insert into polnet.helpers (id, protected_id, helper_id) values (${l.id}, ${l.protected_id}, ${l.helper_id})
        on conflict (protected_id, helper_id) do nothing returning id`;
      return rows.length === 1;
    }) as boolean;
  }
  async helpersOf(protectedId: string) { return (await this.sql`select * from polnet.helpers where protected_id = ${protectedId} order by created_at`).map(link); }
  async helping(helperId: string) { return (await this.sql`select * from polnet.helpers where helper_id = ${helperId} order by created_at`).map(link); }
  async helperUnlink(id: string, memberId: string) {
    if (!isId(id)) return false;
    const rows = await this.sql`delete from polnet.helpers where id = ${id} and (protected_id = ${memberId} or helper_id = ${memberId}) returning id`;
    return rows.length === 1;
  }
  async helperAlertAdd(a: Omit<HelperAlert, "created_at">, now: string, pruneBefore: string) {
    await this.sql`delete from polnet.helper_alerts where protected_id = ${a.protected_id} and created_at < ${pruneBefore}`;
    await this.sql`insert into polnet.helper_alerts (id, protected_id, host, kind, created_at) values (${a.id}, ${a.protected_id}, ${a.host}, ${a.kind}, ${now})`;
  }
  async helperAlertsFor(helperId: string, since: string, limit: number) {
    return (await this.sql`select a.* from polnet.helper_alerts a join polnet.helpers h on h.protected_id = a.protected_id
      where h.helper_id = ${helperId} and a.created_at >= ${since} order by a.created_at desc limit ${limit}`).map(alert);
  }

  async postCreate(p: Omit<Post, "created_at" | "removed">, now: string) {
    const [r] = await this.sql`insert into polnet.posts (id, author, topic, title, body, link, created_at)
      values (${p.id}, ${p.author}, ${p.topic}, ${p.title}, ${p.body}, ${p.link}, ${now}) returning *`;
    return post(r);
  }
  async postGet(id: string) {
    if (!isId(id)) return null;
    const [r] = await this.sql`select p.*, (select count(*)::int from polnet.post_votes v where v.post_id = p.id) as votes,
      (select count(*)::int from polnet.post_comments c where c.post_id = p.id) as comments from polnet.posts p where p.id = ${id}`;
    return r ? post(r) : null;
  }
  async posts(f: { topic?: string; sort: "new" | "top"; limit: number }) {
    const rows = await this.sql`select p.*, (select count(*)::int from polnet.post_votes v where v.post_id = p.id) as votes,
      (select count(*)::int from polnet.post_comments c where c.post_id = p.id) as comments
      from polnet.posts p where not p.removed and (${f.topic ?? null}::text is null or p.topic = ${f.topic ?? null})
      order by ${f.sort === "top" ? this.sql`votes desc,` : this.sql``} p.created_at desc, p.id desc limit ${f.limit}`;
    return rows.map(post);
  }
  async postSetRemoved(id: string, removed: boolean) {
    if (!isId(id)) return false;
    return (await this.sql`update polnet.posts set removed = ${removed} where id = ${id} returning id`).length === 1;
  }
  async postDelete(id: string, author: string) {
    if (!isId(id)) return false;
    return (await this.sql`delete from polnet.posts where id = ${id} and author = ${author} returning id`).length === 1;
  }
  async voteSet(postId: string, memberId: string, on: boolean) {
    if (!isId(postId)) return 0;
    if (on) {
      await this.sql`insert into polnet.post_votes (post_id, member_id) select ${postId}, ${memberId}
        where exists (select 1 from polnet.posts where id = ${postId} and not removed) on conflict do nothing`;
    } else {
      await this.sql`delete from polnet.post_votes where post_id = ${postId} and member_id = ${memberId}`;
    }
    const [c] = await this.sql`select count(*)::int as n from polnet.post_votes where post_id = ${postId}`;
    return Number(c.n);
  }
  async voted(memberId: string, postIds: string[]) {
    const ids = postIds.filter(isId);
    if (ids.length === 0) return [];
    return (await this.sql`select post_id from polnet.post_votes where member_id = ${memberId} and post_id in ${this.sql(ids)}`).map((r) => String(r.post_id));
  }
  async commentCreate(c: Omit<Comment, "created_at">, now: string) {
    if (!isId(c.post_id)) return null;
    const [r] = await this.sql`insert into polnet.post_comments (id, post_id, author, body, created_at)
      select ${c.id}, ${c.post_id}, ${c.author}, ${c.body}, ${now} where exists (select 1 from polnet.posts where id = ${c.post_id} and not removed) returning *`;
    return r ? comment(r) : null;
  }
  async comments(postId: string, limit: number) {
    if (!isId(postId)) return [];
    return (await this.sql`select * from polnet.post_comments where post_id = ${postId} order by created_at, id limit ${limit}`).map(comment);
  }
  async commentDelete(id: string, author: string) {
    if (!isId(id)) return false;
    return (await this.sql`delete from polnet.post_comments where id = ${id} and author = ${author} returning id`).length === 1;
  }

  async hit(key: string, windowMs: number, limit: number, nowMs: number) {
    const since = new Date(nowMs - windowMs).toISOString();
    const [c] = await this.sql`select count(*)::int as n from polnet.hits where key = ${key} and at > ${since}`;
    if (Number(c.n) >= limit) return false;
    await this.sql`insert into polnet.hits (key, at) values (${key}, ${new Date(nowMs).toISOString()})`;
    return true;
  }
}
