// In-memory stand-in for @supabase/supabase-js, good enough to drive the edge
// functions' real code paths in a test. Swapped in by the import map in
// supabase/tests/deno.json, so index.ts is loaded UNMODIFIED — the code under
// test is the code that ships.
//
// Supports only the query shapes the functions actually use. If a function
// grows a new one, this throws rather than silently returning empty — a mock
// that quietly answers "no rows" would turn a broken query into a passing test.

type Row = Record<string, unknown>;

export interface Db {
  tables: Record<string, Row[]>;
  /** Unique constraints, e.g. { payments: ["ref"] } -> insert dup gives 23505. */
  unique: Record<string, string[]>;
  /** Force the next insert into `table` to fail with `error` (F5 coverage). */
  failInsert?: { table: string; error: { code?: string; message: string } };
  /** Every rpc('bump_rate') call, and what it returned. */
  rpcCalls: { name: string; args: Row; returned: number }[];
  /** Counter values keyed by rate-limit bucket. */
  counters: Record<string, number>;
}

export function newDb(seed: Partial<Db["tables"]> = {}): Db {
  return {
    tables: {
      app_config: [], accounts: [], device_sessions: [], devices: [],
      otp_codes: [], otp_requests: [], orders: [], payments: [],
      plans: [], subscriptions: [],
      ...seed,
    } as Record<string, Row[]>,
    unique: { payments: ["ref"] },
    rpcCalls: [],
    counters: {},
  };
}

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));

class Query implements PromiseLike<{ data: unknown; error: unknown }> {
  private filters: { col: string; val: unknown }[] = [];
  private inFilter: { col: string; vals: unknown[] } | null = null;
  private orderBy: { col: string; asc: boolean } | null = null;
  private mode: "many" | "maybeSingle" | "single" = "many";
  private returnRows = false;

  constructor(
    private db: Db,
    private table: string,
    private op: "select" | "insert" | "update" | "upsert" | "delete",
    private payload?: Row | Row[],
    private onConflict?: string,
  ) {}

  select(_cols?: string) {
    // On a write, .select() means "give me the row back".
    if (this.op !== "select") this.returnRows = true;
    return this;
  }
  eq(col: string, val: unknown) { this.filters.push({ col, val }); return this; }
  is(col: string, val: unknown) { this.filters.push({ col, val }); return this; }
  in(col: string, vals: unknown[]) { this.inFilter = { col, vals }; return this; }
  order(col: string, o?: { ascending?: boolean }) {
    this.orderBy = { col, asc: o?.ascending !== false };
    return this;
  }
  maybeSingle() { this.mode = "maybeSingle"; return this; }
  single() { this.mode = "single"; return this; }

  private rows(): Row[] {
    return this.db.tables[this.table] ??= [];
  }

  private matches(r: Row): boolean {
    for (const f of this.filters) {
      const got = r[f.col] ?? null;
      if ((f.val ?? null) !== got) return false;
    }
    if (this.inFilter && !this.inFilter.vals.includes(r[this.inFilter.col])) {
      return false;
    }
    return true;
  }

  private run(): { data: unknown; error: unknown } {
    const all = this.rows();

    if (this.op === "insert" || this.op === "upsert") {
      const incoming = (Array.isArray(this.payload) ? this.payload : [this.payload!]);
      const written: Row[] = [];
      for (const raw of incoming) {
        const row = clone(raw);
        if (this.op === "insert") {
          const fail = this.db.failInsert;
          if (fail && fail.table === this.table) {
            this.db.failInsert = undefined;
            return { data: null, error: fail.error };
          }
          const uniq = this.db.unique[this.table];
          if (uniq && all.some((r) => uniq.every((c) => r[c] === row[c]))) {
            return {
              data: null,
              error: { code: "23505", message: `duplicate key on ${uniq.join(",")}` },
            };
          }
          if (row.id === undefined) row.id = crypto.randomUUID();
          all.push(row);
          written.push(row);
        } else {
          const keys = (this.onConflict ?? "id").split(",").map((s) => s.trim());
          const hit = all.find((r) => keys.every((k) => r[k] === row[k]));
          if (hit) {
            Object.assign(hit, row);
            written.push(hit);
          } else {
            if (row.id === undefined) row.id = crypto.randomUUID();
            all.push(row);
            written.push(row);
          }
        }
      }
      if (!this.returnRows) return { data: null, error: null };
      return this.shape(written);
    }

    const hits = all.filter((r) => this.matches(r));

    if (this.op === "update") {
      for (const r of hits) Object.assign(r, clone(this.payload as Row));
      return this.returnRows ? this.shape(hits) : { data: null, error: null };
    }
    if (this.op === "delete") {
      this.db.tables[this.table] = all.filter((r) => !hits.includes(r));
      return { data: null, error: null };
    }

    let out = hits;
    if (this.orderBy) {
      const { col, asc } = this.orderBy;
      out = [...out].sort((a, b) => {
        const x = String(a[col] ?? ""), y = String(b[col] ?? "");
        return asc ? x.localeCompare(y) : y.localeCompare(x);
      });
    }
    return this.shape(out);
  }

  private shape(rows: Row[]): { data: unknown; error: unknown } {
    if (this.mode === "many") return { data: clone(rows), error: null };
    if (rows.length === 0) {
      return this.mode === "single"
        ? { data: null, error: { code: "PGRST116", message: "no rows" } }
        : { data: null, error: null };
    }
    return { data: clone(rows[0]), error: null };
  }

  then<A, B>(
    onOk?: ((v: { data: unknown; error: unknown }) => A | PromiseLike<A>) | null,
    onErr?: ((e: unknown) => B | PromiseLike<B>) | null,
  ): PromiseLike<A | B> {
    return Promise.resolve(this.run()).then(onOk, onErr);
  }
}

export function makeClient(db: Db) {
  return {
    from(table: string) {
      return {
        select: (cols?: string) => new Query(db, table, "select").select(cols),
        insert: (p: Row | Row[]) => new Query(db, table, "insert", p),
        upsert: (p: Row | Row[], o?: { onConflict?: string }) =>
          new Query(db, table, "upsert", p, o?.onConflict),
        update: (p: Row) => new Query(db, table, "update", p),
        delete: () => new Query(db, table, "delete"),
      };
    },
    // Mirrors the real bump_rate: increment the bucket, return the new count.
    rpc(name: string, args: Row) {
      if (name !== "bump_rate") throw new Error(`unmocked rpc: ${name}`);
      const key = String(args.p_device);
      const n = (db.counters[key] = (db.counters[key] ?? 0) + 1);
      db.rpcCalls.push({ name, args: clone(args), returned: n });
      return Promise.resolve({ data: n, error: null });
    },
  };
}

/** Set by the harness before each function module is imported. */
export let activeDb: Db | null = null;
export function useDb(db: Db) { activeDb = db; }

export function createClient(_url: string, _key: string) {
  if (!activeDb) throw new Error("useDb() must be called before createClient");
  return makeClient(activeDb);
}
