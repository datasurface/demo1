---
name: wire-datatransformer
description: Add and verify a DataTransformer in demo1. Use for PII masking, Python or dbt transforms, derived datasets, output modes, downstream wiring, and SCD4 verification.
---
# Wire a DataTransformer

Use this skill when the user wants to add a DataTransformer (DT) to their demo1 model — the mechanism that produces derived/masked data (PII masking, aggregation, dbt models) from an existing Datastore. demo1 ships with zero DT coverage today, so this is usually a from-scratch addition.

## Concept

A DataTransformer reads one or more input Workspaces (views over already-merged data) and writes an **output Datastore**, which DataSurface then ingests exactly like any other source — full SCD4 current (`_m`) + history (`_mh`) tables, its own batch metrics, its own CQRS replica. There are two DT flavors:

- **Python DT** (`PythonRepoCodeArtifact`) — your own code in a versioned repo, including the framework's built-in tokenizer for masking.
- **dbt DT** (`DBTCodeArtifact`) — runs a dbt project's models against the merge database.

## Step 1: Decide Python custom code vs. the built-in tokenizer

If the goal is PII masking/tokenization specifically, prefer the framework's built-in tokenizer over hand-written masking code — it already handles vaulting, hashing/HSM strategies, and history propagation. Reach for a custom `PythonRepoCodeArtifact` or `DBTCodeArtifact` only when the transform is bespoke (aggregation, joins, derived columns, non-masking dbt models).

### ⚠️ SCD4-only for the built-in tokenizer

The built-in tokenizer is **lint-rejected when the platform milestoning strategy is SCD1** (live-only). On SCD1 the tokenizer's input table holds only live rows, so a source delete never reaches the tokenizer — it emits `'U'` rows but never `'D'`, meaning a PII subject-erasure request in the source would silently never propagate to the tokenized output. DataSurface's lint blocks this configuration outright (ruled 2026-07-04) rather than trying to patch around it. **demo1's `SCD4` platform is history-capable, so this does not affect you here** — this is only a caveat for a customer who later adds an SCD1 platform and tries to reuse the same tokenizer wiring.

## Step 2a: Wire the built-in tokenizer (masking)

The tokenizer is driven by a helper that adds the Workspace + DataTransformer + output Datastore for you, rather than hand-assembling `DataTransformer(...)`:

```python
from datasurface.dt import addTokenizingWorkspace, TokenizationStrategy
from datasurface.policy import SimpleDC, SimpleDCTypes
from datasurface.security import Credential, CredentialType

PUB = SimpleDC(SimpleDCTypes.PUB)
PII = SimpleDC(SimpleDCTypes.PC3, "pii")

# Mark which columns get tokenized directly on the source Dataset's DDLColumns,
# e.g. in your Datastore("CustomerDB", ...) definition:
#   DDLColumn("email", VarChar(100), classifications=[PII]),
#   DDLColumn("phone", VarChar(100), classifications=[PII]),
#   DDLColumn("firstname", VarChar(100), classifications=[PUB]),

addTokenizingWorkspace(
    ecosys,
    "CustomerMaskWorkspace",          # workspace name
    "CustomerDB",                      # source Datastore (or the Datastore object)
    [PII],                             # which classifications to tokenize
    Credential("customer-mask-runner", CredentialType.USER_PASSWORD),
    maskedStoreName="MaskedCustomers",  # output Datastore name
    tokenizationStrategy=TokenizationStrategy.DATABASE_NATIVE_HASH_WITH_VAULT,
)
```

`addTokenizingWorkspace` registers the Workspace/DataTransformer/output Datastore on the owning Team and returns the Workspace. There is also `createTokenizedDatastore(...)` (same arguments) if you just want the output `Datastore` object back. Both live in `datasurface.dt`.

## Step 2b: Wire a custom Python or dbt DataTransformer

For bespoke transforms, assemble the `DataTransformer` explicitly inside a `Workspace`, alongside a `DatasetGroup` that sinks the **input** data the transform reads:

```python
from datasurface.dsl import (
    Workspace, DatasetGroup, DatasetSink, DataPlatformManagedDataContainer,
    DataTransformer, DataTransformerOutputMode, Datastore, Dataset,
)
from datasurface.schema import DDLTable, DDLColumn, NullableStatus, PrimaryKeyStatus
from datasurface.types import VarChar, Date
from datasurface.documentation import PlainTextDocumentation
from datasurface.security import Credential, CredentialType
from datasurface.triggers import CronTrigger
from datasurface.codeartifact import PythonRepoCodeArtifact
from datasurface.repos import GitHubRepository, VersionedRepository, EnvRefReleaseSelector
from datasurface.policy import SimpleDC, SimpleDCTypes

Workspace(
    "MaskedStoreGenerator",
    DataPlatformManagedDataContainer("MaskedStoreGenerator container"),
    DatasetGroup(
        "Original",
        sinks=[DatasetSink("CustomerDB", "customers")],   # the DT's input
    ),
    DataTransformer(
        name="MaskedCustomerGenerator",
        code=PythonRepoCodeArtifact(
            VersionedRepository(
                GitHubRepository("<owner>/<dt-repo>", "main", credential=Credential("git", CredentialType.API_TOKEN)),
                EnvRefReleaseSelector("custMaskRev"),      # resolved via the Team's EnvironmentMap.dtReleaseSelectors
            )
        ),
        trigger=CronTrigger("Every 1 minute", "*/1 * * * *"),
        outputMode=DataTransformerOutputMode.IUD,          # or DataTransformerOutputMode.SNAPSHOT
        runAsCredential=Credential("Yellow_MaskCustomerGenerator", CredentialType.USER_PASSWORD),
        store=Datastore(
            name="MaskedCustomers",                        # the DT's output Datastore
            documentation=PlainTextDocumentation("MaskedCustomers datastore"),
            datasets=[
                Dataset(
                    "customers",
                    schema=DDLTable(columns=[
                        DDLColumn("id", VarChar(20), nullable=NullableStatus.NOT_NULLABLE, primary_key=PrimaryKeyStatus.PK),
                        DDLColumn("firstname", VarChar(100), nullable=NullableStatus.NOT_NULLABLE),
                        DDLColumn("email", VarChar(100)),
                    ]),
                    classifications=[SimpleDC(SimpleDCTypes.PUB, "Customer")],
                )
            ],
        ),
    ),
)
```

For a dbt DT, swap `PythonRepoCodeArtifact` for `DBTCodeArtifact` (`datasurface.dt.dbt`) and pass `imageKey=EnvRefDockerImage("<key>")` pointing at a docker image registered in the Team's `EnvironmentMap.dtDockerImages`. The Team's `EnvironmentMap` also needs the matching `dtReleaseSelectors` entry (`EnvRefReleaseSelector("custMaskRev")` above resolves against it).

### Output mode: IUD vs SNAPSHOT

- **IUD** (`DataTransformerOutputMode.IUD`) — the transformer emits incremental insert/update/delete rows. Use this when the transform can compute per-row change status (most masking/derivation cases, and required if the transform's own code writes an `I`/`U`/`D` marker column). This is what demo1's SCD4 merge is built to consume efficiently.
- **SNAPSHOT** — the transformer rewrites its full output every run; DataSurface diffs against the previous snapshot to derive changes. Simpler to write, more expensive to run at scale. Use it for small/derived datasets or when the transform genuinely can't determine incremental changes (e.g. some aggregations).

## Step 3: Wire the downstream consumer

Consumers sink the DT's **output Datastore/Dataset** — never the physical DT table — the same way they'd sink any other Datastore:

```python
Workspace(
    "Consumer1",
    DataPlatformManagedDataContainer("Consumer1 container"),
    DatasetGroup(
        "LiveDSG",
        sinks=[
            DatasetSink("CustomerDB", "customers"),        # raw data, if this consumer also needs it
            DatasetSink("MaskedCustomers", "customers"),   # the DT's masked output
        ],
        platform_chooser=WorkspacePlatformConfig(
            hist=ConsumerRetentionRequirements(
                r=DataMilestoningStrategy.SCD4,
                latency=DataLatency.MINUTES,
                regulator=None,
            )
        ),
    ),
)
```

## Step 4: Validate, deploy, verify

1. **Lint locally** before pushing — see the `validate-model-locally` skill (or run `python -c "from eco import createEcosystem; createEcosystem()"` / `pytest test_loads.py` as a quick check).
2. **Push the change** via the `edit-model-fragment` skill — commit to the owning Team's branch to open a PR.
3. After merge and publication of a new stable model release, trigger
   `demo-psp_infrastructure`. Its model-merge and factory-creation tasks refresh the dynamic DAG
   set. Discover the DT's DAG name rather than assuming a fixed factory DAG ID:
   ```bash
   kubectl exec -n demo1 airflow-scheduler-0 -c scheduler -- \
     airflow dags trigger demo-psp_infrastructure
   kubectl exec -n demo1 airflow-scheduler-0 -c scheduler -- \
     env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR airflow dags list --output json
   kubectl exec -n demo1 airflow-scheduler-0 -c scheduler -- \
     airflow dags unpause <dt-dag-name>
   kubectl exec -n demo1 airflow-scheduler-0 -c scheduler -- \
     airflow dags trigger <dt-dag-name>
   ```
4. **Verify the DT ran and the output landed.** The DT's own raw write schema is `ds_dt_<workspace>_<datatransformer>` (all lowercased), e.g. `ds_dt_maskedstoregenerator_maskedcustomergenerator.dt_maskedcustomers_customers`. The ingested/consumer-visible copy follows demo1's normal SCD4 layout in `ds_dp_scd4`:
   ```sql
   -- Raw DT output write target
   select count(*) from ds_dt_<workspace>_<datatransformer>.dt_<outputstore>_<dataset>;

   -- Ingested current-snapshot table (what consumers actually read)
   select count(*) from ds_dp_scd4.<outputstore>_<dataset>_m;

   -- Batch metrics for the output store
   select * from scd4_batch_metrics where key = '<OutputStoreName>' order by batch_id desc limit 5;
   ```
   Confirm the real schema/table names via `information_schema.columns` rather than guessing — exact names depend on your workspace/DT names.

## Step 5: Verify the transform is correct

Use `verify-data-fidelity` for the general fidelity check (row counts match source, no silent truncation). For masking specifically, spot-check that PII columns are actually masked in the output and not merely copied through:

```sql
-- Compare a few rows source vs. masked output by key
select id, email, phone from ds_dp_scd4.customers_m where id = '<some-id>';
select id, email, phone from ds_dp_scd4.maskedcustomers_customers_m where id = '<some-id>';
```

- Row counts between `<source>_m` and `<maskedoutput>_m` should match (masking changes values, not row presence).
- Masked/tokenized columns should be transformed — not equal to the source value and not empty/NULL (empty/NULL usually means the transform silently dropped the column instead of masking it).
- If using `outputMode=DataTransformerOutputMode.IUD`, a source-row delete should propagate to a delete in the output's `_mh` history table (`batch_out` closes) — this is exactly the property the SCD1 tokenizer lint exists to protect, so it's worth checking once after first wiring.

## Report

```
DataTransformer Wiring Report
==============================
DT Workspace:      <name>
Output Datastore:  <name>
Flavor:            Built-in tokenizer | Custom Python | dbt
Output Mode:       IUD | SNAPSHOT

Model lint:         ✅ / ❌
DT DAG created:     ✅ / ❌  (infrastructure factory-creation task)
DT DAG succeeded:   ✅ / ❌
Output row count:   ✅ matches source | ⚠️ mismatch (<source_count> vs <output_count>)
Masking verified:   ✅ PII columns transformed | ⚠️ not checked | ❌ PII columns unchanged
```
