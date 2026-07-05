---
name: Verify Data Fidelity
description: Prove DataSurface moved data faithfully from source through primary merge to any CQRS replica, with zero loss or corruption. Use when the user asks "did my data move correctly?", "verify data fidelity", "compare source to merge", "is the merge/CQRS data correct?", "any data loss?", or "audit the pipeline".
---
# Verify Data Fidelity

Use this skill to prove — not just assume — that DataSurface carried the customer's data faithfully across every tier: **source → primary merge (SCD4) → CQRS replica**. This is the platform's core promise. `check-system-health` covers throughput and DB health; this skill covers correctness of the data itself.

## IMPORTANT: Execution Rules

1. **Read-only.** Every check in this skill only runs `SELECT`. Never `UPDATE`/`DELETE`/`INSERT` against source, merge, or CQRS while auditing.
2. **Discover, don't hardcode.** Table names, business columns, and connection details come from the model files and `information_schema` at runtime — this skill must work for any customer model, not just the demo `customers`/`addresses` tables.
3. **Classify before alarming.** A mismatch between merge and CQRS is often benign replication lag, not data loss. Follow the classification rules in Step 5 before reporting a failure.
4. **One table at a time for large tables.** Don't load full business-column sets for >100k-row tables into memory at once — use the hash-based comparison in Step 5.

## Background: SCD4 physical layout

For each ingested dataset `<name>`, the merge schema (`ds_dp_scd4`, derived from the lower-cased platform name — `SCD4` in this repo) contains:

- `<name>_m` — **current** table: exactly one live row per key, plus `ds_surf_batch_id`, `ds_surf_all_hash`, `ds_surf_key_hash`.
- `<name>_mh` — **history** table: closed prior versions, plus `ds_surf_all_hash`, `ds_surf_key_hash`, `ds_surf_batch_in`, `ds_surf_batch_out` (inclusive-last-live milestoning — a version live for exactly one batch has `batch_in == batch_out`).
- `<name>_vf` — a view over current; safe to query instead of `_m` directly.

A CQRS replica (if configured) has the same `_m`/`_mh` layout in `ds_dp_scd4` on the target database.

## Step 1: Discover Connections (Merge + Source + CQRS)

```bash
# Merge database + platform name
grep -r "PostgresDatabase\|SQLServerDatabase\|merge_datacontainer\|mergeRW_Credential\|databaseName" rte_*.py eco.py *.py 2>/dev/null

# Source datastore containers (per ingestion) — look for the DataContainer backing each Datastore
grep -r "Datastore(\|CaptureMetaData\|SQLServerDatabase\|PostgresDatabase\|sourceCredential" *.py 2>/dev/null

# CQRS / ConsumerReplicaGroup targets — not every model has one
grep -r "ConsumerReplicaGroup\|CQRS\|cqrs" rte_*.py *.py 2>/dev/null
```

Resolve credentials from K8s secrets (check both key styles):

```bash
kubectl get secret <credential-name> -n <namespace> -o jsonpath='{.data.USER}' | base64 -d; echo
kubectl get secret <credential-name> -n <namespace> -o jsonpath='{.data.PASSWORD}' | base64 -d; echo
# or a single connection-string secret:
kubectl get secret <credential-name> -n <namespace> -o jsonpath='{.data.connection}' | base64 -d; echo
```

If K8s access isn't available, ask the user for the merge, source, and (if present) CQRS credentials directly. If the model has no CQRS/`ConsumerReplicaGroup` configured, skip Step 5 and note it as "not applicable" in the report — that is not a failure.

## Step 2: Discover the SCD4 Tables

Run against the merge database:

```sql
-- Every dataset's current table in the SCD4 schema
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'ds_dp_scd4' AND table_name LIKE '%\_m' ESCAPE '\'
ORDER BY table_name;
```

For each `<name>_m` found, discover its business columns (everything except the `ds_surf_*` framework columns — this is what makes the script work for any model):

```sql
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'ds_dp_scd4' AND table_name = '<name>_m'
  AND column_name NOT LIKE 'ds\_surf\_%' ESCAPE '\'
ORDER BY ordinal_position;
```

## Step 3: Run the Integrity, Hash, and Milestoning Checks

These three checks only touch the merge database and need no source/CQRS connection. Run this script per discovered `<name>_m`/`<name>_mh` pair — either locally with `psycopg`/`pyodbc` if you have DB access, or piped into a pod that has the right driver:

```bash
kubectl exec -i <merge-or-mcp-pod> -n <namespace> -- env PGM="$PGM" python3 - <<'PY'
import os, psycopg

merge = psycopg.connect(os.environ['PGM'])
mc = merge.cursor()

# TABLES: discovered in Step 2 -> list of business columns discovered in Step 2
TABLES = {
    # 'customerdb_customers': ['id', 'firstName', 'lastName', 'dob', 'email', 'phone', 'primaryAddressId', 'billingAddressId'],
}

total_fail = 0
for TAB, BIZ in TABLES.items():
    Q = ', '.join(f'"{c}"' for c in BIZ)
    print(f"\n########## {TAB} ##########")
    fails = []

    # 1. Current-table integrity: exactly one live row per key, no NULL hashes.
    mc.execute(
        f'select count(*), count(distinct "id"), count(distinct ds_surf_key_hash), '
        f'count(*) filter (where ds_surf_all_hash is null or ds_surf_key_hash is null) '
        f'from ds_dp_scd4.{TAB}_m'
    )
    n, ni, nk, nn = mc.fetchone()
    if n != ni: fails.append(f"_m {n-ni} dup-id live rows")
    if n != nk: fails.append(f"_m {n-nk} dup-keyhash live rows")
    if nn: fails.append(f"_m {nn} NULL hashes")
    print(f"  [1 integrity] rows={n} distinct_id={ni} distinct_kh={nk} null_hash={nn} -> {'OK' if not fails else 'FAIL'}")

    # 2. Hash<->value consistency: one hash <=> one set of business values, both directions.
    mc.execute(
        f'select count(*) from (select ds_surf_all_hash from ds_dp_scd4.{TAB}_m '
        f'group by ds_surf_all_hash having count(distinct ({Q}))>1) t'
    )
    hv1 = mc.fetchone()[0]
    mc.execute(
        f'select count(*) from (select ({Q}) v from ds_dp_scd4.{TAB}_m '
        f'group by ({Q}) having count(distinct ds_surf_all_hash)>1) t'
    )
    hv2 = mc.fetchone()[0]
    if hv1: fails.append(f"{hv1} all_hash groups with DIFFERENT values (divergence)")
    if hv2: fails.append(f"{hv2} value groups with DIFFERENT all_hash")
    print(f"  [2 hash<->value] hash->multivalue={hv1} value->multihash={hv2} -> {'OK' if not (hv1 or hv2) else 'FAIL'}")

    # 3. Milestoning integrity: no batch_in > batch_out; history ranges chain with no gaps/overlaps.
    #    Note: batch_in == batch_out is a VALID one-batch version under inclusive-last-live milestoning.
    mc.execute(
        f'select count(*) filter (where ds_surf_batch_in>ds_surf_batch_out) inv, '
        f'count(*) filter (where ds_surf_batch_in=ds_surf_batch_out) eq, count(*) tot '
        f'from ds_dp_scd4.{TAB}_mh'
    )
    inv, eq, tot = mc.fetchone()
    mc.execute(
        f'with h as (select ds_surf_key_hash, ds_surf_batch_out bout, '
        f'lead(ds_surf_batch_in) over (partition by ds_surf_key_hash order by ds_surf_batch_in) nx '
        f'from ds_dp_scd4.{TAB}_mh) select count(*) from h where nx is not null and nx<>bout+1'
    )
    gaps = mc.fetchone()[0]
    if inv: fails.append(f"{inv} history in>out")
    if gaps: fails.append(f"{gaps} history gaps/overlaps")
    print(f"  [3 milestoning] hist_rows={tot} in>out(invalid)={inv} in==out(1-batch,ok)={eq} chain_gaps={gaps} -> {'OK' if not (inv or gaps) else 'FAIL'}")

    if fails:
        total_fail += 1
        print(f"  === {TAB} FAILS: {fails}")
    else:
        print(f"  === {TAB}: CLEAN")

print(f"\n########## OVERALL: {total_fail} table(s) with integrity/hash/milestoning FAILs ##########")
PY
```

Any FAIL here means the merge tier itself is broken — do not proceed to blame source or CQRS lag until this is clean.

## Step 4: Source → Merge Value Fidelity

Compare business-column values between each ingestion source and its `_m` current table. Differences are classified, not just counted — a source row that changed *after* the last merge batch committed is benign lag; a truncated string, a `?`-substitution, or precision loss is real corruption and can never come from lag alone.

```bash
kubectl exec -i <merge-or-mcp-pod> -n <namespace> -- env PGM="$PGM" PGSRC="$PGSRC" SSSRC="$SSSRC" python3 - <<'PY'
import os, psycopg
# import pyodbc  # only if you have a SQL Server source

def norm(t):
    return tuple(str(x) if x is not None else None for x in t)

def corrupt(sv, mv, col):
    """Detect patterns that can ONLY be data loss, never benign lag."""
    if sv is None or mv is None:
        return None
    ss_, ms = str(sv), str(mv)
    if '?' in ms and '?' not in ss_:
        return f"?-SUBST col={col} src={ss_!r} merge={ms!r}"
    if len(ms) < len(ss_) and ss_.startswith(ms):
        return f"TRUNCATION col={col} src={ss_!r} merge={ms!r}"
    return None

merge = psycopg.connect(os.environ['PGM'])
mc = merge.cursor()

# One job per (merge table, source cursor/connection, source query, business columns).
# Discover BIZ (business columns) from Step 2's information_schema query; quote per the
# SOURCE container's own dialect (double-quotes for Postgres, [brackets] for SQL Server) —
# do not reuse the merge side's quoting for the source side.
def run(mtab, scur, squery, biz, label):
    Q = ', '.join(f'"{c}"' for c in biz)  # merge side is always Postgres -> double-quote
    scur.execute(squery)
    src = {r[0]: norm(r) for r in scur.fetchall()}
    mc.execute(f'select {Q} from ds_dp_scd4.{mtab}_m')
    mrg = {r[0]: norm(r) for r in mc.fetchall()}
    common = set(src) & set(mrg)
    exact = 0
    corr = []
    for k in common:
        if src[k] == mrg[k]:
            exact += 1
        else:
            for i, c in enumerate(biz):
                x = corrupt(src[k][i], mrg[k][i], c)
                if x:
                    corr.append((k, x))
    print(f"[{label}] source={len(src)} merge={len(mrg)} common={len(common)} exact={exact} "
          f"differ={len(common)-exact} src_only={len(set(src)-set(mrg))} "
          f"merge_only={len(set(mrg)-set(src))} CORRUPTION={len(corr)}")
    for k, x in corr[:10]:
        print("    ", k, x)
    return len(corr)

# Fill in per your model's ingestions, e.g.:
# CUST = ['id', 'firstName', 'lastName', 'dob', 'email', 'phone', 'primaryAddressId', 'billingAddressId']
# pg_src = psycopg.connect(os.environ['PGSRC']); ps = pg_src.cursor()
# bad = run('customerdb_customers', ps,
#           'select {} from public.customers'.format(', '.join(f'"{c}"' for c in CUST)),
#           CUST, 'PG-src customers -> merge')
PY
```

`differ` rows that are NOT flagged as `CORRUPTION` are presumed benign lag (the source changed since the last committed batch). `differ` count with `CORRUPTION == 0` is healthy. Any `CORRUPTION > 0` is a real fidelity bug — stop, report the exact key/column/source-value/merge-value, do not adjust the comparison to make it pass.

## Step 5: Merge → CQRS Fidelity (Lag-Robust)

Skip this step entirely if the model has no CQRS/`ConsumerReplicaGroup` configured (checked in Step 1).

Compare merge `_m` to the CQRS replica's `_m` using the compact `ds_surf_all_hash` per key rather than full business columns — this is memory-light and valid *because* Step 3 already proved hash↔value is 1:1 in the merge tables. For every key where the hashes differ, check whether the CQRS hash is a **valid prior version** of that key (present in merge `_m` or `_mh`): if yes, that's benign replication lag; if the CQRS hash matches no merge version at all for that key, that's real divergence.

```bash
kubectl exec -i <merge-or-mcp-pod> -n <namespace> -- env PGM="$PGM" CQRS="$CQRS" python3 - <<'PY'
import os, psycopg, pyodbc  # swap pyodbc for psycopg if the CQRS target is Postgres

merge = psycopg.connect(os.environ['PGM']); mc = merge.cursor()
cqs = pyodbc.connect(os.environ['CQRS']); qc = cqs.cursor()

TABLES = {
    # 'customerdb_customers': ['id', 'firstName', ...],   # same map as Step 3, one table at a time
}

for TAB, BIZ in TABLES.items():
    QPG = ', '.join(f'"{c}"' for c in BIZ)
    QSS = ', '.join(f'[{c}]' for c in BIZ)  # adjust bracket/quote style to the CQRS target's dialect
    fails = []

    mc.execute(f'select ds_surf_key_hash, ds_surf_all_hash from ds_dp_scd4.{TAB}_m')
    mh = {r[0]: r[1] for r in mc.fetchall()}
    ver = {}
    for kh, ah in mh.items():
        ver.setdefault(kh, set()).add(ah)
    mc.execute(f'select ds_surf_key_hash, ds_surf_all_hash from ds_dp_scd4.{TAB}_mh')
    for r in mc.fetchall():
        ver.setdefault(r[0], set()).add(r[1])

    qc.execute(f'select ds_surf_key_hash, ds_surf_all_hash from ds_dp_scd4.{TAB}_m')
    qh = {r[0]: r[1] for r in qc.fetchall()}

    common = set(mh) & set(qh)
    diff = [k for k in common if mh[k] != qh[k]]
    benign = sum(1 for k in diff if qh[k] in ver.get(k, set()))
    bad = [k for k in diff if qh[k] not in ver.get(k, set())]
    if bad:
        fails.append(f"{len(bad)} CQRS hashes match NO merge version (REAL DIVERGENCE)")

    heq = sum(1 for k in common if mh[k] == qh[k])
    if heq == 0 and common:
        fails.append("CQRS all_hash never equals merge all_hash (different hash scheme? cannot lag-verify by hash)")

    print(f"[{TAB}] merge={len(mh)} cqrs={len(qh)} common={len(common)} hash-exact={heq} "
          f"diff={len(diff)} benign-lag(valid-prior-version)={benign} REAL-DIVERGENCE={len(bad)} "
          f"-> {'OK' if not bad else 'FAIL'}")
    for k in bad[:5]:
        mc.execute(f'select {QPG} from ds_dp_scd4.{TAB}_m where ds_surf_key_hash=%s', (k,))
        mrow = mc.fetchone()
        qc.execute(f'select {QSS} from ds_dp_scd4.{TAB}_m where ds_surf_key_hash=?', k)
        qrow = qc.fetchone()
        print("      DIVERGENCE kh=", k[:14], " merge=", mrow, " cqrs=", tuple(qrow) if qrow else None)
    if fails:
        print(f"  === {TAB} FAILS: {fails}")
PY
```

## Step 6: Report

```
Data Fidelity Report
=====================
Merge DB: <host>:<port>/<dbname>
CQRS target: <host>:<port>/<dbname> | not configured

Per-dataset results:

Dataset                        Integrity  Hash<->Value  Milestoning  Src->Merge  Merge->CQRS
customerdb_customers            ✅         ✅            ✅           ✅          ⚠️ (lag)
customerdb_addresses            ✅         ✅            ✅           ✅          ✅

Issues Found:
  - <none | list each ❌ with dataset, key, column, source/merge/cqrs values, and classification>

Notes:
  - ⚠️ = benign replication lag (CQRS holds a valid older version of a still-changing key) — expected, not a failure.
  - ❌ = real fidelity loss: duplicate/lost current rows, hash<->value divergence, milestoning gaps,
    corruption patterns (truncation, ?-substitution) in source->merge, or a CQRS value matching no
    merge version at all. Any ❌ must be reported with the exact key and values — never narrowed away.
```

Use ✅ for clean, ⚠️ for benign/explained (lag), ❌ for a real fidelity failure. If any ❌ appears, stop and report it with specifics rather than re-running with a looser comparison.
