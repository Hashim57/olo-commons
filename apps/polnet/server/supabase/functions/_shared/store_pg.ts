// deno-lint-ignore-file no-explicit-any
// The Store over Postgres (the polnet schema, sql in ../../migrations/001_polnet.sql). Uses the postgres
// driver because the Edge Function connects with SUPABASE_DB_URL as the owner; the schema grants nothing
// to anon or authenticated. Racy operations run in one transaction with row locks.

import postgres from "npm:postgres@3.4.5";
import type { Claim, ClaimError, LedgerEntry, Member, PolName, ReportKind, Store, Task, TaskStatus } from "./store.ts";

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

  async hit(key: string, windowMs: number, limit: number, nowMs: number) {
    const since = new Date(nowMs - windowMs).toISOString();
    const [c] = await this.sql`select count(*)::int as n from polnet.hits where key = ${key} and at > ${since}`;
    if (Number(c.n) >= limit) return false;
    await this.sql`insert into polnet.hits (key, at) values (${key}, ${new Date(nowMs).toISOString()})`;
    return true;
  }
}
