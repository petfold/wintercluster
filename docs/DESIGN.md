# wintercluster — design v0.1

*(Name settled: lowercase, one word. A honeybee colony survives winter by forming a **winter cluster** — the bees ball around the queen and live off the stores they sealed away in autumn. This is a backup tool for Kubernetes clusters, so the pun is free and the metaphor is exact: seal the stores while it is warm, survive on them when it is not.)*

**One sentence:** Velero backs up Kubernetes to Swarm through s3warm; wintercluster makes every backup recoverable from the bare Swarm network — no cloud account, no gateway, no metadata index, no surviving cluster — by capturing each backup's commit root into a small, signed, escrowable **recovery card**.

**The pitch in one line:** a cluster's entire disaster-recovery position reduces to one commit root, one feed coordinate pair, and two user-held secrets (a recovery passphrase and the Kopia repository password).

**Status of this document:** design only, no code exists. Every claim about s3warm is marked **[VERIFIED]** (read from the repo's own docs at `main`, 2026-08-31: `docs/DESIGN.md`, `docs/REFERENCE.md`, `ROADMAP.md`) or **[ASSUMED]** (must be confirmed in milestone M0 before any implementation — see `TASKS.md`). Where M0 can come back with different answers, the design branches are written out.

---

## 1. Scope

**In scope (v1):**
- `wintercluster-agent` — in-cluster controller: watches Velero `Backup` CRs, snapshots the BSL bucket at backup completion, produces and escrows recovery cards.
- `wintercluster` CLI — verifies cards, renders them for humans (text + QR), and orchestrates tier-B/C restores.
- Small additions to s3warm (as PRs to that repo): feed-owner surfacing, a stateless read-only serving mode from a bare root, hardening of the rebuild-from-root path. Each is listed in §12.
- The recovery-card format (schema, signing, encryption, sinks).
- Demo (`demos/06-kubernetes-dr.sh` in s3warm), an end-to-end restore drill in CI, and a benchmark harness.

**Out of scope (v1):**
- A native Velero ObjectStore plugin (the stock AWS plugin against s3warm is the whole point).
- ACT-protected buckets as BSL targets — **[VERIFIED]** the commit chain is off for ACT buckets (it would leak key names and structure), and the chain is what wintercluster stands on. BSL buckets use SSE-S3.
- Kasten/other backup tools, multi-cluster fleet management, any UI.
- Stamp-underwriting integration (insured retention) — a natural v2; noted in §13.

---

## 2. What s3warm already provides — [VERIFIED]

These are the load-bearing facts, from s3warm's own reference docs. Do not re-derive them; re-verify them in M0 against the code and a live stack.

| Capability | Interface | Notes |
|---|---|---|
| Per-bucket commit chain | Mantaray manifest per commit; one fork per object (entry = object reference, Content-Type in metadata, so `GET /bzz/{root}/{key}` works on any Bee node); reserved `.s3warm/commit` fork holds a JSON commit document | Commit document: `{version, bucket, seq, parent, timestamp, objects:[{Key, SwarmRef, ETag, …full index rows}]}`. Parent links make the chain walkable backwards from any root. The `objects` array is the exact-restore source of truth. Zero-byte objects appear only in the commit document; composite (multipart) objects appear as JSON descriptors `{"s3warm":"composite/1","parts":[…]}` |
| Commit barrier + labeled snapshot | `PUT /{bucket}?x-swarm-snapshot=<label>` | **Forces a commit**, records label → root, pins the root on the gateway's Bee node, returns `{bucket, label, root, seq, createdAt}`. This is exactly the barrier the agent needs — no new s3warm API required for capture |
| Snapshot listing | `GET /{bucket}?x-swarm-snapshot` | JSON list |
| Atomic whole-bucket restore | `POST /{bucket}?x-swarm-restore=<label or 64-hex root>` | Replaces the entire object set from the commit document, points the head at that root. Accepts **any** commit root whose document names the same bucket, including roots from before a restore (roll-forward works). Returns `{bucket, root, seq, objects}` |
| Cheap root reads | `HeadBucket` → `x-swarm-bucket-root`, `x-swarm-commit-seq` | Any S3 client can capture a root without the snapshot extension |
| Feed checkpoints | `-feed-key <hex secp256k1>`; owner = the key's Ethereum address, topic = `keccak256("s3warm/1/" + bucket)`, sequence feed, index = `seq − 1`, payload = the 32-byte commit root | Resolvable on **any** Bee node: `GET /feeds/{owner}/{topic}?type=sequence` — the portable recovery anchor. Verified live upstream. Checkpoint policy is currently every-commit; interval/manual are open upstream |
| Money keeps itself running | Chequebook auto top-up + opt-in stamp autopilot (`-stamp-autopilot`): tops up batches below `-stamp-ttl-min`, dilutes mutable batches at utilization threshold, Prometheus counters | The stamp-lifecycle keeper this design would otherwise have had to build |
| S3 dialect coverage | 307 Ceph s3-tests green: multipart (range-stitched composite reads), conditional writes, presigned URLs, streaming signatures, five checksum algorithms, SSE-S3, versioning, tagging, CORS, multi-tenant credentials, Postgres HA index | Everything Velero's stock AWS plugin and Kopia's S3 repository exercise on paper; empirical confirmation is milestone M1 |
| SSE-S3 | `x-amz-server-side-encryption: AES256` → `swarm-encrypt: true`; Bee encrypts; the 64-byte reference embeds the decryption key and "lives only in the index"; `x-swarm-reference` suppressed on responses | **[CORRECTED]** "lives only in the index" is false for multipart objects — the 64-byte reference reaches the public commit document verbatim. See `docs/GAPS.md` A1 |
| Delete semantics | Index rows removed; manifest fork removed on next commit; **physical bytes remain until their batch expires** | The ransomware-resistance property, stated plainly in s3warm's own docs |
| Rebuild-from-feed | Documented as the recovery procedure ("the index remains a cache… losing it is an inconvenience, not data loss"); admin surface lists "index rebuild-from-feed" | **[ASSUMED]** implementation status — not checked off in ROADMAP; M0 determines whether `?x-swarm-restore=<root>` on a fresh gateway already covers it (see A2) |
| Versioning caveat | "Bucket restore flattens version history" | Irrelevant if the BSL bucket has versioning off — which this design mandates (§5.4) |

---

## 3. Assumptions to verify — M0 gates

Implementation must not start until each item below has a written answer in `docs/GAPS.md` (M0 deliverable). Where the answer changes the design, both branches are pre-written here.

**A1 — Do key-bearing SSE references appear in the commit chain?** — **[RESOLVED — see `docs/GAPS.md`]**

**Answer: branch (c), plus branch (a)'s leak on the composite path.** Single-part SSE objects make the bucket's commit *fail* (`invalid entry size: 64, expected: 32` — mantaray manifests are single-width and the commit document is always a 32-byte reference), freezing the chain until the object is deleted. Multipart SSE objects commit fine and publish every part's 64-byte key-bearing reference, in cleartext, in a commit document readable from any Bee node. Evidence, reproduction, and remedy options are in `docs/GAPS.md`; the remedy is Peter's call.

Two consequences bind the rest of this document. **`public_root` stays closed** — the root is a read capability today, so it lives in `sensitive` (§6.1). And **§5.4's SSE-S3 mandate currently contradicts the commit chain**, which is the one thing this project stands on; nothing downstream of the chain is safe for an SSE bucket until an upstream fix lands.

The original three branches are kept below for the record. Branch (b)'s remedy is the pre-written answer to what was found.

The commit document carries full index rows, and for an SSE object the index holds the 64-byte key-bearing reference. The chain's manifests are public (that is their point: `bzz://` browsability). Three possible findings:

- *(a) SSE refs are in the commit document / manifest forks.* Then **any commit root of an SSE bucket is a read capability for the whole bucket**. Consequences: the recovery card's root field is secret material (the card design in §6 already assumes this); the feed must not be treated as public (its payload is the root); and s3warm should document this loudly. wintercluster works unchanged.
- *(b) SSE objects are excluded or opaque in the chain.* Then the chain alone cannot restore SSE objects, and tier-B/C restores are broken for exactly the objects that matter (Velero resource tarballs containing cluster `Secret`s). Remedy, as an s3warm proposal: include SSE refs in the commit document but encrypt those entries (or the whole `objects` array) under a per-bucket **recovery public key** (age recipient) supplied at bucket creation; the matching identity lives only in the recovery card's encrypted section. This keeps the chain public *and* restorable-by-keyholder.
- *(c) SSE + commit chain currently don't combine at all* (like ACT). Same remedy as (b), or v1 falls back to gateway-side at-rest encryption semantics being provided by Kopia only (see §11 — acceptable for volume data, not for resource tarballs).

**A2 — Does `?x-swarm-restore=<root>` work on a fresh gateway with an empty index?**
The docs say restore accepts any root whose document names the same bucket. Unknowns: must the bucket exist first (presumably `CreateBucket` then restore); which bucket-level state is *not* in the commit document and must be re-established by hand (default encryption config, batch binding, tagging, CORS); does restore re-pin the root. M0 produces the exact fresh-gateway procedure as a numbered runbook — that runbook *is* tier B.

**A3 — Is the feed owner discoverable through the API?**
The card needs `(owner address, topic)`. Topic is derivable (`keccak256("s3warm/1/" + bucket)`); the owner address of `-feed-key` appears to be surfaced nowhere. Proposal (§12): `x-swarm-feed-owner` on `HeadBucket`, plus a checkpoint-lag indicator (`x-swarm-feed-seq` vs `x-swarm-commit-seq`). Until then the agent takes the owner address as configuration.

**A4 — Empirical Velero/Kopia compatibility.**
On paper everything is covered; M1 confirms under load: ListObjectsV2 delimiter listing as Velero uses it for backup sync, range GETs on composite objects during Kopia restores, checksum-algorithm negotiation (Velero ≥1.14 sets `checksumAlgorithm`; document the working value or the `""` fallback), Kopia maintenance deletes, presigned GET for `velero backup download`.

**A5 — Retrieval requirements for tier C.**
Confirm a light Bee node suffices for chain walking + object retrieval, and measure the effect of the erasure-coding fetch strategies s3warm already exposes (`-fetch-strategy`, `x-swarm-redundancy-strategy`) on restore throughput.

**A6 — Snapshot lifetime vs Velero retention.**
Snapshot lifetime is bounded by the postage batch that stamped the commit; pinning protects only against the gateway node's local GC. Confirm which batch stamps commit-chain chunks (bucket's bound batch? gateway default?) so §10's TTL-alignment rule points at the right batch.

---

## 4. Recovery tiers and threat model

### Tiers

| Tier | What is lost | What survives | Restore path |
|---|---|---|---|
| **A** | Nothing (or just the cluster) | s3warm + index + Bee node | Plain `velero restore` against the BSL. wintercluster not involved |
| **B** | Gateway host: s3warm process, Postgres/SQLite index, local Bee node and its pins | The Swarm network; the recovery card (or just the feed coordinates) | Fresh s3warm + any Bee node → `CreateBucket` → `POST ?x-swarm-restore=<root>` (root from card, or resolved from the feed) → re-mint S3 credentials → `velero restore` |
| **C** | Everything above **plus** no s3warm anywhere (can't or won't run a gateway with a writable index) | The Swarm network + the recovery card + user-held secrets | `s3warm serve --read-only --root <root>` (stateless, no index — §12) or `wintercluster materialize --root <root> --out dir/` → point Velero at the read-only endpoint → `velero restore` |

Tier C is the demo and the reason to build this: *"wreck the cluster and the gateway; restore the workload from a hash, a passphrase, and any Bee node."*

### Threat model (what an attacker can and cannot do)

| Attacker holds | Can | Cannot |
|---|---|---|
| S3 credentials to the BSL bucket | Wreck the index view: delete objects, overwrite keys, create garbage commits; burn batch capacity (autopilot spends money — rate limits/quotas are an s3warm concern, noted upstream) | Rewrite history: prior commit roots are immutable content on Swarm; physical bytes persist until batch expiry. Every pre-attack card still restores |
| The gateway host (root) | All of the above, plus unpin roots on the local node, read the index (incl. key-bearing SSE refs), read `-feed-key`, publish fraudulent feed updates | Delete chunks from the network; forge *signed* recovery cards without the agent's key |
| The agent's signing key | Forge cards | Make a forged card restore to attacker data without also holding write access to produce a plausible commit chain — and forged cards fail cross-checks against feed history and Velero CR annotations |
| A recovery card but no passphrase | Read the public fields (bucket name, seq, timestamps; the root **only if** A1 lands on branch (b)/(c) where the root is not a capability — under branch (a) the root itself lives in the encrypted section) | Decrypt the sensitive section; decrypt Kopia blobs (repo password is separate) |
| Everything except the user-held secrets | — | Read SSE-protected resource tarballs or Kopia volume data. The passphrase + Kopia password are the last line, held by humans |

**Ransomware framing (the sales pitch, kept honest):** deleting or encrypting the backups requires deleting chunks from Swarm, which nobody — including the owner — can do before stamp expiry. The attacker's best move is stopping stamp payments, which the autopilot resists and which still leaves a TTL-long recovery window. The mutable index is wreckable, but it is a cache; wintercluster's job is making sure the immutable roots are always findable afterwards.

---

## 5. Architecture

```
 Kubernetes cluster                          gateway host                    Swarm
┌──────────────────────────────┐      ┌──────────────────────────┐
│ Velero server ── Backup CRs  │ S3   │  s3warm ── index (PG)    │  Bee   ┌────────┐
│ node-agent (Kopia FSB)  ─────┼─────▶│    │  commit chain ──────┼───────▶│network │
│                              │      │    │  stamp autopilot    │        │        │
│ wintercluster-agent             │      │    └ feed checkpoints ───┼───────▶│ feeds  │
│   watch Backup CRs           │      └──────────▲───────────────┘        └────▲───┘
│   PUT ?x-swarm-snapshot ─────┼─ S3 + x-swarm ──┘                             │
│   write recovery card ───────┼── sinks: Backup CR annotation, file,          │
│                              │          webhook, escrow feed ────────────────┘
└──────────────────────────────┘
 restore tier C:  wintercluster CLI + any Bee node + card  →  read-only serve / materialize  →  velero restore
```

### 5.1 Interaction contract

The agent and CLI talk to s3warm **only over HTTP** (S3 API + `x-swarm-*` extensions) and to Bee only over its HTTP API. No Go-level imports of s3warm (`internal/` is unimportable by design); no shared database access. This keeps wintercluster a separate repo with a stable dependency surface, and keeps every capability it relies on documented in s3warm's REFERENCE.md — if wintercluster needs something undocumented, the fix is an s3warm PR (§12), not a private hook.

### 5.2 wintercluster-agent (in-cluster)

A single-replica Deployment in the `velero` namespace. Reconciliation loop:

1. **Watch** Velero `Backup` CRs. Trigger on transition into a terminal phase: `Completed` or `PartiallyFailed` (both get cards; the card records the phase). Terminal-phase semantics matter: with CSI snapshot data movement, `DataUpload` operations finish before the Backup leaves `Finalizing`, so at trigger time every object of that backup — resource tarball, Kopia blobs, `velero-backup.json` — has landed in the bucket. **[ASSUMED]** exact phase-machine details per installed Velero version; pin and verify in M1.
2. **Barrier + capture:** `PUT /{bucket}?x-swarm-snapshot=velero-{backupName}` → `{root, seq, createdAt}`. Label charset (`[A-Za-z0-9._-]{1,64}`) accommodates Velero backup names; enforce/truncate with a hash suffix if needed.
3. **Assemble the recovery card** (§6): bucket config snapshot (from `HeadBucket`, `GetBucketEncryption`, batch headers), feed coordinates, snapshot result, Velero context, TTL margin.
4. **Sign, encrypt, escrow** to every configured sink (§6.3).
5. **Verify (optional, on by default, budgeted):** fetch the commit document at `root` from the Bee node, check that a sample (or all) of the keys under `backups/{backupName}/` and `kopia/` prefixes listed by S3 also appear in the commit document with matching ETags. Emit `wintercluster_verify_failures_total` on mismatch.
6. **Metrics** (Prometheus): `wintercluster_cards_written_total{sink}`, `wintercluster_last_card_age_seconds`, `wintercluster_snapshot_failures_total`, `wintercluster_ttl_margin_seconds` (batch TTL minus the longest live Velero backup TTL — the alert that prevents the silent-expiry failure mode), `wintercluster_verify_failures_total`.

Failure stance: card production must never fail a backup (it runs after the fact) but must never fail *silently* — every sink write is retried with backoff, surfaced in metrics, and recorded as an Event on the Backup CR.

Also handled: `DeleteBackupRequest` — when Velero deletes a backup, the agent annotates (not deletes) the corresponding card records as superseded; the immutable chain retains the data until stamp expiry regardless, and the docs say so plainly (compliance posture: deletion on Swarm is stamp expiry plus, for SSE, key destruction — crypto-shredding).

### 5.3 wintercluster CLI

- `wintercluster card verify <card>` — signature, schema, feed cross-check (resolve feed, confirm the card's root appears in the chain), optional Bee-side existence probe of the root.
- `wintercluster card render <card>` — human-readable sheet + QR (the "print this and put it in the safe" artifact).
- `wintercluster restore --card <card> [--tier b|c]` — orchestrates the runbooks in §7: talks to a fresh s3warm (tier B) or drives the read-only path (tier C), then prints the exact `velero` commands. It orchestrates; it does not reimplement Velero restore.
- `wintercluster find --owner <addr> --bucket <name>` — no card at all: derive the topic, resolve the feed on any Bee node, walk parent links, list restorable roots with timestamps. The floor of recoverability: feed coordinates alone.

### 5.4 Deployment rules (documented, enforced by the Helm chart where possible)

- One BSL bucket per cluster, **versioning off** (Velero doesn't need it; bucket restore flattens version history anyway), **SSE-S3 on** by default — **[BLOCKED: A1 found SSE-S3 and the commit chain mutually exclusive; see `docs/GAPS.md`. This rule and the chain cannot both hold until an upstream remedy ships.]** — (resource tarballs contain every `Secret` in the cluster; Velero does not client-side-encrypt them), commit mode `sync` or default async — snapshot forces a commit either way.
- Gateway + its Bee node run **outside** the cluster being backed up. The in-cluster convenience deployment exists for demos only and prints a warning.
- `-feed-key` mandatory for DR-grade deployments; without it, tier B/C depend on someone having saved a root, and `wintercluster find` is dead.
- Kopia (Velero file-system backup / data mover) is the volume path; its repository password is user-held secret material, never stored by wintercluster.

---

## 6. The recovery card

### 6.1 Schema (JSON, canonical serialization for signing)

```json
{
  "card_version": 1,
  "created_at": "2026-08-31T12:00:00Z",
  "cluster":   { "name": "…", "velero_backup": "…", "velero_phase": "Completed", "velero_version": "…" },
  "bucket":    { "name": "…", "endpoint_hint": "https://…", "versioning": false,
                 "sse_default": "AES256", "batch_id": "…", "batch_ttl_at_capture": "…" },
  "snapshot":  { "label": "velero-…", "seq": 42, "committed_at": "…" },
  "feed":      { "owner": "0x…", "topic_rule": "keccak256('s3warm/1/'+bucket)", "topic": "0x…", "type": "sequence" },
  "public_root": "…",
  "sensitive":  "<age armor: encrypted under the recovery passphrase / recipients>",
  "restore_hint": "One paragraph of prose: which CLI command, which secrets you need, where the docs live.",
  "signature":  { "scheme": "eip191-secp256k1", "signer": "0x…", "sig": "0x…" }
}
```

- `public_root` vs `sensitive`: under A1 branch (a) — root is a capability — `public_root` is omitted and the root lives inside `sensitive` (with the bucket recovery key material, if branch (b)'s remedy lands). Under branches (b)/(c), the root is public and `sensitive` holds only key material. The schema supports both; the A1 answer picks the default.
- `sensitive` is [age](https://age-encryption.org)-encrypted: passphrase recipient always; optional additional X25519 recipients (ops team keys). The Kopia repository password is **not** stored unless the operator explicitly opts in (`--include-kopia-password`, discouraged, documented).
- Signature: EIP-191 over the canonical JSON minus the signature field — the same signed-snapshot pattern the ecosystem already uses (radicle-index-service). The agent's key is a plain secp256k1 key in a Secret; its address is published in the chart values so verifiers know what to expect.

### 6.2 Rendering

`card render` emits: the JSON, a human sheet (what this is, what it restores, what else you need, the three-command restore), and a QR of the JSON. The design intent is a one-page PDF an operator prints and stores offline — the off-Swarm root copy that makes the whole scheme non-circular.

### 6.3 Sinks

| Sink | Purpose | Notes |
|---|---|---|
| Backup CR annotation | Tier-A convenience: `velero backup describe` shows the card | Size-capped; store the card minus `sensitive` if over limit, with a pointer |
| Local file / mounted volume | Simple durable copy | Append-only JSONL |
| Webhook | Ship to a password manager, ticketing, or printer pipeline | At-least-once, retried |
| Escrow feed on Swarm | `owner = agent key, topic = keccak256("wintercluster/1/" + cluster)`; payload = the encrypted card | Discoverability of the *latest* card from the bare network. Circular by design (Swarm storing its own recovery data) — which is why the printed/off-site copy is the canonical one and the docs say so |
| stdout | Log-scraping fallback | Card minus `sensitive` |

---

## 7. Flows

### 7.1 Backup time

```
Velero: Backup → … → Finalizing → Completed
agent:  observe terminal phase
        PUT /{bucket}?x-swarm-snapshot=velero-{name}      → {root, seq}
        HeadBucket                                        → batch id, TTL, (feed owner, §12)
        assemble card → sign → age-encrypt sensitive part
        write sinks; annotate Backup CR; verify commit doc against S3 listing
        update metrics (ttl_margin, last_card_age)
```

### 7.2 Tier A

`velero restore create --from-backup {name}`. wintercluster uninvolved. (Listed so runbooks always start from the cheapest tier.)

### 7.3 Tier B — gateway and index lost

1. Provision any Bee node (light node acceptable per A5) and a fresh s3warm with a new empty index; mint fresh S3 credentials.
2. Recover the root: from the card's `public_root`/`sensitive`; or, with no card, `wintercluster find --owner … --bucket …` → resolve `GET /feeds/{owner}/{topic}?type=sequence` → latest root → walk `parent` links to choose an earlier point if needed.
3. `CreateBucket` with the config from the card (SSE default, batch binding), then `POST /{bucket}?x-swarm-restore=<root>` → index rebuilt for that bucket (A2 runbook governs the details).
4. Point Velero's BSL at the fresh gateway (`s3Url`, `s3ForcePathStyle: true`, any region label); `velero backup get` syncs; `velero restore create`.

### 7.4 Tier C — no writable gateway at all

1. Decrypt the card's `sensitive` with the recovery passphrase → root (+ key material per A1 outcome).
2. `s3warm serve --read-only --root <root>` against any Bee node (§12): stateless, in-memory index built by walking the manifest and commit document; serves GET/HEAD/List only. (Fallback if that feature is descoped: `wintercluster materialize --root <root> --out ./bucket/` then serve with anything, at the cost of local disk = bucket size.)
3. Point Velero's BSL at the read-only endpoint; restore. Kopia decrypts volume data with the user-held repository password.

The flagship drill (M6) executes 7.4 on a machine that has never seen the original cluster, gateway, or index, and asserts byte-identical workload data.

---

## 8. Consistency analysis

- **The snapshot is a consistent cut.** All writes for a backup precede its terminal phase; the snapshot forces a commit after that; therefore the commit document is a superset of the backup's object set. Concurrent unrelated writes (a second schedule, Kopia maintenance) may also be in the cut — harmless, the card belongs to the bucket state, and Velero reads by key.
- **Kopia maintenance vs old roots.** Maintenance deletes unreferenced blobs; a root captured at backup *N* still contains every blob referenced *at that time*, so restoring the bucket to root *N* yields an internally consistent Kopia repository as of *N*. Rolling a bucket back resurrects since-deleted objects; Velero re-syncs and shows old backups again; Kopia GCs the extras. Documented, not fought.
- **Multi-writer.** Velero server + node-agents write concurrently through one gateway (or several over the shared Postgres index — supported upstream). The chain serializes at commit level; nothing here assumes single-writer.
- **Checkpoint lag.** The feed may trail the head (policy-dependent; currently every-commit upstream). The card carries the exact root, so lag only affects the card-less `wintercluster find` floor — surface the lag via §12's headers and a metric.

---

## 9. Performance: the differential argument

Why incremental flow largely sidesteps Swarm's throughput ceiling in steady state:

1. **Kopia CDC:** only changed pack blobs are uploaded; unchanged data never leaves the cluster. Nightly upload ∝ data churn, not dataset size.
2. **Resource tarballs are small** (MBs for most clusters) and compress well.
3. **Commit chain structural sharing:** unchanged forks are shared between commits; a commit costs only the changed path's node chain [VERIFIED upstream].
4. **Content addressing:** identical chunks map to identical addresses and reuse batch slots; re-uploads of unchanged content don't grow the batch.

What the ceiling still owns — and what the benchmark harness (M6) therefore measures as headline numbers:

- **First full backup** of realistic PV sizes (10 / 50 / 200 GB), per ack tier (`-ack` network/node) and redundancy level.
- **Full restore throughput** — the number this whole direction is judged on. Measure via 7.3 and 7.4, varying erasure-coding fetch strategy, Kopia parallelism, and Bee node type (full vs light).
- **Steady-state nightly** at 1% / 5% / 20% churn.
- **Time-to-first-byte for a resource-only restore** (the "get the cluster's brain back in minutes, volumes later" story — worth reporting separately because it is the realistic first hour of a disaster).

No performance numbers are asserted in this design; producing them honestly is a deliverable.

---

## 10. Stamps and retention

Rule: **batch TTL ≥ longest Velero backup TTL + safety margin**, continuously enforced, not set-and-forgotten. The stamp autopilot [VERIFIED] keeps batches topped up and diluted; wintercluster adds the Velero-aware check: `wintercluster_ttl_margin_seconds` compares the BSL bucket's batch TTL (from `x-swarm-batch-ttl` headers) against live Backup CR expirations, with a shipped alert rule. A backup that outlives its stamp is the one silent failure mode this system must never allow; it gets a metric, an alert, and a line in every card (`batch_ttl_at_capture`).

Snapshot pinning protects roots from the *gateway node's* local GC only [VERIFIED]; network persistence is the batch's job (A6 confirms which batch). Retention of history = keeping the batch alive; deletion = letting it lapse (+ key destruction for SSE). Both directions documented.

---

## 11. Security notes

- **The card is secret-by-default.** Even if A1 concludes roots are not capabilities, cards name buckets, clusters, and infrastructure; and under branch (a) the root *is* the bucket. Encrypted section always present; sinks documented with that assumption.
- **Custody:** recovery passphrase and Kopia repository password are human-held, stored outside all systems this design can lose. The printed card + password manager is the recommended pairing. wintercluster never persists either.
- **Resource tarballs:** Velero does not client-side-encrypt them and they contain every cluster `Secret` — hence SSE-S3 mandatory on the BSL bucket, and hence A1 is the gating question for tier-C completeness.
- **Agent key:** rotate by publishing the new address in chart values; `card verify` accepts a configured set of valid signers with validity windows.
- **Fraudulent feed updates** (gateway-key theft): cards pin exact roots and seq numbers; `verify` cross-checks card ↔ feed ↔ chain and flags divergence rather than trusting any single source.

---

## 12. Proposed s3warm additions (PRs upstream, kept minimal)

| Addition | Why | Size |
|---|---|---|
| `x-swarm-feed-owner` (+ `x-swarm-feed-seq`) on `HeadBucket` | A3: cards need feed coordinates without out-of-band config; lag becomes observable | Small |
| `serve --read-only --root <ref>` mode | Tier C without local disk = bucket size; stateless gateway over an immutable root is also independently useful (share a snapshot as a live S3 endpoint) | Medium — M0 decides serve-mode vs `materialize`-only for v1 |
| Fresh-gateway restore runbook hardening | A2: whatever `CreateBucket`+`restore-by-root` doesn't cover (bucket config, re-pinning) gets fixed or documented | Small–medium |
| SSE-in-chain remedy | Only if A1 lands on branch (b)/(c): recovery-recipient encryption of SSE entries in the commit document | Medium; needs upstream design discussion first |
| `demos/06-kubernetes-dr.sh` | The flagship demo lives where the other five live | Small |

---

## 13. Open questions (beyond the M0 gates)

1. Should the escrow feed carry every card or only a rolling latest-N? (Feed updates are stamped SOCs; cost vs history.)
2. Card format registration: is a media type + `.wintercluster.json` extension enough, or align with an existing DR-manifest convention?
3. Multi-BSL clusters (rare): one agent watching all BSLs, cards carry the BSL name — any reason not to?
4. v2: stamp-underwriting integration — an underwritten batch behind the BSL bucket turns "backups persist" from an ops promise into an on-chain guarantee; the card would carry the policy reference. Design separately once v1 drills pass.
5. v2: PSS/GSOC notification of new checkpoints to off-site listeners (upstream has this as open research).

## 14. Terminology

**"Cluster" always means the Kubernetes cluster** — in this document, in code, in metric help strings, in user-facing output. The project's name is a pun on the bee formation, but the word is never reused for it: write `wintercluster` when you mean the project. The card schema's `cluster` field is the Kubernetes one.

The recovery card is called the **recovery card** (or just *the card*), everywhere — schema, CLI, metrics, prose. It is the printable, signed artifact of §6; no alternative name for it appears in docs or code.

Otherwise, terms follow the swarm skill / s3warm docs: *reference*, *chunk*, *postage stamp/batch*, *feed*, *manifest/Mantaray*, *commit chain*, *checkpoint*, *ACT*. Where this document says "root" it means a bucket commit root: the 32-byte reference of a commit's Mantaray manifest.
