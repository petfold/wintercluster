# GAPS — M0 recon findings

Answers to DESIGN.md §3's A1–A6, from s3warm's code and a live stack rather than its docs. Each answer carries file/line evidence and, where the design branches, a demonstration.

**Status: A1, A2, A3, A5, A6 answered — A1, A2 and A5 demonstrated on a live stack, A1 and A5 against real Swarm. A4 open (M1).**

Environment for every live result below: s3warm at `05a45c8`, its `docker-compose.yml` dev stack (fakebee + SQLite index), Bee library `v2.8.1`, probes driven over plain S3 sigv4. Where fakebee's fidelity limits a conclusion, it is said so explicitly.

---

## A1 — Do key-bearing SSE references appear in the commit chain?

**Answer: both failure modes at once, split by object layout. Neither is DESIGN.md's expected branch (a).**

| Object | Commit | Outcome |
|---|---|---|
| Single-part SSE (`PUT` with `x-amz-server-side-encryption: AES256`) | **Fails, permanently** | The bucket's commit chain freezes. No new roots, no feed checkpoints. |
| Multipart SSE (composite) | Succeeds | The 64-byte key-bearing reference of **every part** is published in cleartext in the commit document on Swarm. |

Velero's BSL bucket contains both shapes. So under DESIGN §5.4's mandated configuration — SSE-S3 on, which is non-negotiable because resource tarballs contain every cluster `Secret` — a real bucket would both freeze its chain *and* leak capabilities for the objects that did commit.

This is DESIGN.md's **branch (c)** ("SSE and the commit chain currently don't combine at all"), plus branch (a)'s leak on the composite path. The pre-written remedy still applies, but the problem is bigger than the branch anticipated: it is not that SSE objects are excluded gracefully, it is that the mechanism errors out.

### Why single-part SSE cannot commit

Mantaray fixes a manifest's reference width from its first entry and rejects any entry of a different width:

- `bee/v2@v2.8.1/pkg/manifest/mantaray/node.go:182-186` — `refBytesSize` is set from the first entry added, then `invalid entry size: %d, expected: %d` for any mismatch.

A plain object reference is 32 bytes; an SSE object's reference is 64 (address + embedded decryption key); the commit document's own reference is **always** 32, because it is saved through a plain `/bytes` upload:

- `internal/manifest/manifest.go` — `Build` adds one fork per object via `entryFor`, whose default branch hex-decodes `o.SwarmRef` with no `Encrypted` check, then adds the commit document under `.s3warm/commit` using `ls.Save(doc)`, which never encrypts.

Both orderings therefore fail, which is why there is no safe object mix:

```
mixed bucket (plaintext first):   adding "secret.tar.gz": invalid entry size: 64, expected: 32
all-SSE bucket (SSE first):       invalid entry size: 32, expected: 64   ← the commit document
```

The second error is unprefixed, which localizes it: object adds are wrapped `adding %q`, the `.s3warm/commit` add is not.

**Live demonstration.** Against the compose stack:

1. `PUT /ctrl-sse`, `PUT /ctrl-sse/a.txt` (plaintext), `PUT /ctrl-sse?x-swarm-snapshot=before-sse` → `200`, root `d526c59a…`, seq 1.
2. `PUT /ctrl-sse/secret.tar.gz` with `x-amz-server-side-encryption: AES256` → `200`. The write succeeds.
3. `PUT /ctrl-sse?x-swarm-snapshot=after-sse` → **`503 ServiceUnavailable`**, `invalid entry size: 64, expected: 32`.
4. `HEAD /ctrl-sse` → root and seq unchanged at `d526c59a…` / 1. The chain is frozen at step 1.
5. `DELETE /ctrl-sse/secret.tar.gz` → `204`; snapshot now succeeds at seq 2. Removing the SSE object un-freezes the chain.

A control bucket with only plaintext objects commits normally throughout.

### Why this is worse than a failed request

For wintercluster the failure is at least loud: the agent's snapshot barrier gets a `503` and can alarm. For s3warm itself it is silent. Background commits are debounced and log-only:

- `internal/manifest/committer.go` — `Run` logs `commit failed` at warn level and moves on; `CommitNow` clears the bucket's dirty flag *before* building, so a failed commit is not retried until the next mutation.

So an operator using s3warm without wintercluster gets: S3 writes returning `200`, objects readable, and a commit chain that stopped advancing at the first SSE write, discoverable only in gateway logs. Every downstream recovery property — feed checkpoints, snapshots, restore-by-root — quietly stops covering new data.

### What the composite path publishes

SSE multipart commits succeed because the fork entry is a `composite/1` JSON descriptor (a 32-byte reference to a saved chunk), so the width check passes. The 64-byte part references travel inside that descriptor and inside the commit document's `objects[].Parts[].SwarmRef`.

Fetched from a **bare Bee node**, with only a root and no gateway, index, or credentials:

```json
{ "version": 1, "bucket": "sse-mpu", "seq": 1,
  "objects": [ { "Key": "kopia/big-pack", "SwarmRef": "", "Encrypted": true,
    "BatchID": "50a5d9ab…",
    "Parts": [ { "PartNumber": 1,
                 "SwarmRef": "b0a38309…c419b0a38309…c419",   ← 128 hex = 64 bytes
                 "Size": 5242880 }, … ] } ] }
```

`store.Object` carries no JSON tags (`internal/store/store.go`), so `json.Marshal` emits every exported field — `SwarmRef`, `Encrypted`, `BatchID`, user metadata — under its Go name. Nothing is filtered on the way into the chain.

This directly contradicts s3warm's own documentation:

- s3warm `docs/DESIGN.md:296` (§12) — "The 64-byte reference (which embeds the decryption key) lives only in the index; `x-swarm-reference` is suppressed for encrypted objects."

The suppression is real on the S3 response path (`internal/api/object.go:495` guards on `!obj.Encrypted`, with a comment explaining that ACT references are safe to expose but these are not). The gateway protects the reference on one channel and publishes it on another.

Note the ACT precedent: 64-byte-reference buckets already broke the chain once, and that case *is* handled — `ErrACTBucket` in `internal/manifest/committer.go` disables commits for ACT buckets, documented in s3warm's `docs/DESIGN.md:247` and `docs/REFERENCE.md:308`. SSE has the same reference width and got no such treatment.

### Consequence for the recovery card

The capability chain is fully public for composite objects. A feed topic is `keccak256("s3warm/1/" + bucket)` — derivable from a guessable bucket name — so an attacker with the feed owner address alone resolves the feed, gets the head root, walks it on any Bee node, and reads the part references that decrypt every multipart object. No credentials, no gateway.

So DESIGN §6.1's `public_root` default must stay closed: **the root is a capability today, and card `sensitive` must hold it.** That matches branch (a)'s consequence even though the mechanism is branch (c)'s. It is Peter's call (CLAUDE.md) whether an upstream fix changes that later; until one lands and ships, no card should carry a public root for an SSE bucket.

### Remedy options (for review — not chosen here)

s3warm already has the shape for a fix. `composite/1` proves the pattern: when an entry cannot be a bare 32-byte reference, save a JSON descriptor and reference *that*.

- **(i) Descriptor indirection.** Represent SSE objects as an `sse/1` descriptor holding the 64-byte reference. Commits work for all layouts, uniformly 32-byte manifests. Does not fix the leak — it generalizes it to single-part objects too.
- **(ii) Descriptor indirection + recovery-recipient encryption.** As (i), but the reference-bearing fields (or the whole `objects` array) are encrypted to a per-bucket recovery public key supplied at bucket creation, with the identity living only in the card's `sensitive` section. Keeps the chain public and browsable, keeps restore possible for the keyholder, closes the leak. This is DESIGN.md's pre-written branch-(b) remedy and it now covers branch (c) as well.
- **(iii) Refuse and document.** Disable the chain for SSE buckets exactly as ACT does. Honest and small, but it kills tier B/C for the only bucket configuration this project can safely recommend — i.e. it ends the project as designed.

(ii) is the only option that leaves wintercluster viable with SSE mandated. It needs upstream design discussion before code.

Independent of the choice, two smaller upstream items fall out:

- Fail loudly. A commit that cannot be built should surface beyond a log line — a metric at minimum, since a frozen chain is invisible from the S3 API.
- The commit document leaks more than references: full key names, sizes, ETags, batch IDs, user metadata. Worth stating plainly in s3warm's docs for *all* buckets, not just SSE ones.

### Confidence

Verified by construction and reproduction: the width conflict, both error directions, the chain freeze, the un-freeze on delete, and the verbatim contents of a commit document fetched from a bare Bee node.

**The leak is confirmed on real hardware.** Against a live funded Bee light node (v2.8.2, Gnosis, batch `8e8f5f1b…`, depth 17):

| Upload | Reference returned |
|---|---|
| `POST /bytes` | `859c2a44…` — 64 hex, 32 bytes |
| `POST /bytes` + `swarm-encrypt: true` | `9f86dbf5…15f6b8` — **128 hex, 64 bytes** |

Then, supplying no key anywhere:

- `GET /bytes/{full 64-byte reference}` → **`200`, `Content-Length: 73`, the plaintext back verbatim.**
- `GET /bytes/{first 32 bytes only}` → `200` but `Content-Length: 4288851400860880` (~4.3 PB) and no content: with the key half stripped, Bee reads the encrypted chunk's span field as cleartext and gets nonsense.

So the second half of the reference *is* the decryption key, possession of the whole reference is sufficient to read the bytes, and the address half alone is useless. Every one of those 64-byte references sits in cleartext in a commit document that any Bee node will serve to anyone holding the root.

**And it is exercisable from the open internet with `curl`.** The same 64-byte reference, handed to the public Swarm gateway at `api.gateway.ethswarm.org`, returned the plaintext:

```
$ curl https://api.gateway.ethswarm.org/bytes/9f86dbf5...15f6b8
wintercluster-a1-live-probe: this stands in for a Velero resource tarball
[http 200, 73B]
```

No key, no credentials, no Bee node of the reader's own. An attacker needs the reference and nothing else — and the reference is published in a commit document reachable from a feed whose topic is derived from the bucket name. This is not a "someone running a Bee node could" finding; it is a plain HTTPS GET.

Nothing about A1 now rests on fakebee. The one part still modelled rather than observed is the *commit* path against a live node, and it does not need observing: the width check that fails is `mantaray.Node.Add` in the Bee library, evaluated locally on reference bytes before any node call, so the node cannot change the outcome.

Incidental A5 datum: a **light** node served both retrievals without a full node anywhere in the picture, which is the first evidence for tier C's node requirement.

---

## A2 — Fresh-gateway restore by root

**Answer: it works, and the data comes back byte-identical from the root alone. Bucket *configuration* does not come back at all, and the restored root is not re-pinned.**

Drill run against the compose stack: populate a bucket, then delete the s3warm container *and* its index volume while leaving the Bee node running — the tier-B position, holding nothing but a 64-hex root.

### The runbook, as tested

1. Provision a Bee node and a fresh s3warm with an empty index. Verify it is empty: `GET /` lists zero buckets.
2. `PUT /{bucket}` — **CreateBucket first.** Restore against a non-existent bucket returns `404 NoSuchBucket`; `handleRestoreBucket` calls `GetBucket` before anything else (`internal/api/snapshot.go`).
3. `POST /{bucket}?x-swarm-restore=<64-hex root>` → `200 {"bucket","root","seq","objects":N}`.
4. Re-establish bucket configuration by hand — see below. Nothing in step 3 does it for you.
5. Re-pin the root by hand — see below.
6. Point Velero's BSL at the gateway and restore.

Steps 1–3 verified end to end: after restore, `ListObjectsV2` returned all three keys and every `GET` returned the original bytes, from a gateway that had never seen the data and an index created seconds earlier. `HEAD` reported the restored root and seq. The commit document is a complete and sufficient description of the *object set*.

### What restore does not carry

The commit document holds `{version, bucket, seq, parent, timestamp, objects}` and nothing else (`internal/manifest/manifest.go`). Every field of `store.Bucket` outside `HeadRoot`/`CommitSeq` is therefore lost. Measured after the drill:

| Bucket state | After restore |
|---|---|
| Objects, content, ETags, metadata | **restored** |
| Head root / commit seq | **restored** |
| Default SSE (`?encryption`) | `404 ServerSideEncryptionConfigurationNotFoundError` |
| Bucket tags (`?tagging`) | `404 NoSuchTagSet` |
| CORS rules (`?cors`) | `404 NoSuchCORSConfiguration` |
| Versioning | back to default (unset) |
| Bucket→batch binding | lost; writes fall back to the gateway default batch |

For wintercluster this validates DESIGN §6.1: the card's `bucket` section is not decoration, it is the only surviving record of how to rebuild the bucket. The agent must capture default SSE, versioning, and the batch binding at capture time, because a fresh gateway cannot learn them from the chain. Restoring a Velero BSL bucket without re-applying default SSE would silently start writing plaintext objects into a bucket the operator believes is encrypted.

The batch binding matters twice over: post-restore writes land on the gateway default batch, whose TTL has no relationship to the one §10's `wintercluster_ttl_margin_seconds` was watching. A restored bucket starts with an unmonitored retention clock.

### Restore does not re-pin

`handleCreateSnapshot` pins its new root best-effort (`s.bee.Pin`); `handleRestoreBucket` never calls `Pin`. So a root recovered onto a fresh node is unprotected from that node's local GC — precisely the root an operator has just proven they depend on. Either s3warm should pin on restore or wintercluster's tier-B runbook must pin explicitly; the former is a two-line upstream change and belongs with the other §12 PRs.

This one is from code, not measurement: fakebee implements no `/pins` endpoint at all, so pinning silently no-ops in the dev stack — including the *snapshot* pin, which is best-effort and logs a warning on failure. **The M1 harness cannot test pinning as it stands**; either fakebee grows `/pins` or pin assertions run only in the live-Bee profile.

### Constraint on this answer

Per A1, this drill could only be run with SSE off. A bucket with default SSE on cannot produce a commit at all, so there is currently no such thing as a tier-B restore of the configuration DESIGN §5.4 mandates. A2 is answered for the mechanism; it cannot be answered for the intended deployment until A1 has a remedy.

### Follow-up to test (not yet done)

Feed indices are derived as `seq - 1` (`internal/manifest/feed.go`), and `RestoreBucket` resets the head to the restored commit's seq. So rolling back and then writing produces a *second, different* commit at a sequence number whose feed index is already occupied. Sequence-feed updates are single-owner SOCs addressed by `keccak(id, owner)`, so two payloads would contend for one address. Whether Bee rejects the second, keeps the first, or serves either nondeterministically decides how badly a rollback corrupts the recovery anchor — and `wintercluster find` walks exactly that feed. Worth a dedicated test before M2.

## A3 — Feed owner discoverability — **answered from code; no live test needed**

**Confirmed: the feed owner is surfaced nowhere in the API.** `FeedPublisher.Owner()` exists (`internal/manifest/feed.go`) and is called exactly once in the whole tree — a startup log line in `cmd/s3warm/main.go:96`. `HeadBucket` returns `x-swarm-bucket-root` and `x-swarm-commit-seq` but nothing about the feed (`internal/api/bucket.go`).

The topic is derivable without help: `keccak256("s3warm/1/" + bucket)`, confirmed in `FeedPublisher.Topic`. So the owner address is the single missing coordinate, and DESIGN §12's proposed `x-swarm-feed-owner` / `x-swarm-feed-seq` headers are the right fix and a genuinely small one — the accessor already exists and only needs wiring into the HeadBucket handler.

Until that lands the agent takes the owner address as configuration, as DESIGN §3 anticipated. Note the security consequence recorded under A1: since the topic is derivable from the bucket name, publishing the owner address makes the whole chain reachable by anyone — which is fine once roots are not capabilities, and is another reason the A1 remedy must land before the feed coordinates are treated as public.

## A4 — Velero/Kopia empirical compatibility — **open** (M1)

## A5 — Retrieval requirements for tier C

**Answer: a light node is sufficient. Verified end to end on real Swarm.**

Ran s3warm against a live funded Bee **light** node (v2.8.2, batch `8e8f5f1b…`), wrote a 42-byte JSON object and a 2 MiB blob, forced a commit, then **killed the gateway and deleted its index** — leaving only a 64-hex root and the light node. From that position:

1. Resolved the manifest and read `.s3warm/commit` over `GET /bytes`, using Bee's public `mantaray` package. No gateway, no credentials.
2. Fetched each object by the `SwarmRef` in the commit document.
3. Compared SHA-256 against the originals: **both byte-identical**, sizes matching the recorded `Size`.

So tier C's read path needs nothing but a light node and a root. That is the single most load-bearing assumption in the design and it holds. It also means the tier-C client is small: a mantaray walk over `/bytes` plus a per-object GET — which is exactly what `internal/bee` will implement, and it is now demonstrated rather than assumed.

**The throughput figure from this run is not usable and must not be quoted.** The measured 37 MB/s is the node serving chunks it had just uploaded, out of its own local store. It is a local-disk number wearing a network number's clothes. A real figure requires retrieval on a node that has never held the data; until then this project has no restore-throughput evidence at all.

Consequently the erasure-coding half of A5 — the effect of `S3WARM_FETCH_STRATEGY` and `x-swarm-redundancy-strategy` on restore speed — is **not measured** and cannot be measured on a single warm node. It belongs to M6's benchmark harness, which needs a second, cold node in its topology. M6 should treat "the retrieving node must not be the uploading node" as a correctness requirement of the benchmark, not a nicety; the easiest way to get a wrong, flattering number here is to reuse one node.

**Propagation confirmed, and with it the first honest cold-retrieval number.** The same references fetched through the public gateway at `api.gateway.ethswarm.org` — a node that never held the data and had to retrieve it from the network:

| Fetch | Result | Time |
|---|---|---|
| Commit manifest root | `200`, 512 B | 0.56 s |
| Small object (42 B) | `200`, 42 B | 0.52 s |
| 2 MiB object | `200`, 2,097,152 B | 1.80 s — **1.17 MB/s** |

The 2 MiB object was verified byte-identical by SHA-256 against the original. So a light node genuinely pushed the data into the network, the commit chain is retrievable by third parties, and tier C does not depend on the uploading node surviving. That is the property the whole design assumes and it now has direct evidence.

Treat 1.17 MB/s as indicative only, not a benchmark: one object, one sample, through a public gateway that adds its own hop and may cache or rate-limit. It is nonetheless the first number here measured on a node that did not upload the data, and it is roughly 32x slower than the same object served from local store — which is the gap M6 must measure properly.

## A6 — Snapshot lifetime vs Velero retention

**Answer: the bucket's bound batch stamps the commit chain, falling back to the gateway default. The TTL is readable, but not where §10 assumed.**

`CommitNow` picks the batch as `bucket.BatchID`, else the gateway default, and fails the commit if neither exists (`internal/manifest/committer.go`). That same batch is passed to `FeedPublisher.Publish`, so **the commit chain, the commit document, and the feed checkpoint all share one batch** — one TTL governs the entire recovery anchor, which is the simple case §10 hoped for.

Confirmed live: the bucket had no bound batch, and every `objects[].BatchID` in the commit document fetched from Bee read `8e8f5f1b…`, the gateway default.

**Correction to DESIGN §10.** It says the TTL margin is computed "from `x-swarm-batch-ttl` headers", implying the bucket. The header exists (`setBatchHeaders`, `internal/api/object.go`) but is only ever set on **object** responses — `PUT` and the GET/HEAD object path. `HeadBucket` emits `x-swarm-bucket-root` and `x-swarm-commit-seq` and no batch information at all. So the agent must HEAD a known object to learn the batch and its TTL; there is no bucket-level way to ask. Either the agent HEADs an arbitrary object from its own last backup, or `x-swarm-batch-ttl` joins the §12 HeadBucket additions alongside `x-swarm-feed-owner`. The latter is tidier and turns one round trip into zero extra ones.

**Cross-link with A2, and it is the nastier finding.** A tier-B restore does not carry the bucket→batch binding. So after a restore the bucket falls back to the gateway default batch, and every subsequent commit and checkpoint is stamped by a batch with no relationship to the one `wintercluster_ttl_margin_seconds` was watching. The recovery anchor silently changes retention clocks at exactly the moment an operator is least able to notice. The agent must re-read the batch after any restore rather than caching it from the card, and the tier-B runbook must re-apply the batch binding explicitly.

Pinning remains local-GC protection only, as designed — and per A2 it is untestable in the current harness.

---

## Consolidated upstream list for s3warm

M0's real output. Ordered by whether wintercluster can proceed without it.

| # | Change | Size | Blocking? |
|---|---|---|---|
| 1 | **SSE in the commit chain** (A1). Descriptor indirection so SSE objects can be represented at all, plus recovery-recipient encryption of the reference-bearing fields so the chain stops publishing capabilities. Needs design discussion before code. | Medium | **Yes.** No SSE bucket has a commit chain today, and SSE is mandatory for Velero resource tarballs. |
| 2 | **Fail loudly on unbuildable commits** (A1). A frozen chain is invisible from the S3 API and currently surfaces only as a log line. Metric at minimum. | Small | No, but it is what made this bug survivable in the first place |
| 3 | **Re-pin on restore** (A2). `handleRestoreBucket` never pins the root it just restored. | Small (two lines) | No — the runbook can pin by hand |
| 4 | **`x-swarm-feed-owner` / `x-swarm-feed-seq` on HeadBucket** (A3). The accessor exists; it needs wiring to the handler. | Small | No — configuration covers it |
| 5 | **`x-swarm-batch-ttl` on HeadBucket** (A6). Otherwise the agent HEADs an arbitrary object to learn its own retention clock. | Small | No |
| 6 | **Document what the commit chain publishes** (A1). Key names, sizes, ETags, batch IDs and user metadata are public for every bucket, not just SSE ones. s3warm's docs should say so as bluntly as they say it about deletion. | Small | No |
| 7 | **`/pins` in fakebee** (A2). Pinning silently no-ops in the dev stack, so CI cannot test it. | Small | No — but M1's harness must not claim pin coverage until it exists |

Items 3–6 are independent of the A1 remedy and could land first; item 1 wants a design conversation before any code. Item 7 is harness work and could equally live in wintercluster's CI as a live-Bee-only assertion.

## DESIGN.md corrections applied

- §2 — the SSE row's "lives only in the index" claim corrected; it is false for multipart objects.
- §3 A1 — resolved; branch (c) plus branch (a)'s leak recorded, `public_root` default closed.
- §5.4 — the SSE-S3 mandate marked BLOCKED pending the A1 remedy.
- §10 — the TTL source corrected: `x-swarm-batch-ttl` is an object-response header, not a bucket one.

## Reproduction notes

The probes behind these results are session scratch files, not committed. Everything above is reproducible from the numbered steps in each section using any S3 client plus `curl` against Bee; the only non-obvious piece is the chain walk, which is ~40 lines against Bee's public `mantaray` package (`NewNodeRef(root).Lookup(".s3warm/commit")` over `GET /bytes`). Worth committing under `hack/recon/` when M0 closes, since M6's drill needs the same walk.

The live-Swarm runs used a depth-17 batch bought for this purpose; it expires ~24 h after 2026-08-31T07:30Z. Re-running the live sections needs a fresh batch.
