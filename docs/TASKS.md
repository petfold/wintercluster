# wintercluster — implementation plan

Rules of engagement:
- Milestones are ordered; **M0 gates everything**. No implementation code before `docs/GAPS.md` exists and DESIGN.md's `[ASSUMED]` items are resolved.
- Every milestone ends with: tests green in CI, docs updated, a one-paragraph status note appended to this file under its milestone.
- s3warm changes are PRs against `petfold/s3warm`, matching that repo's conventions (its DESIGN.md is the style reference). wintercluster code lives in its own repo.
- When reality contradicts DESIGN.md, reality wins: update DESIGN.md in the same change, marking the correction.

---

## M0 — Recon and gap report *(no code)*

Read, in order: s3warm `docs/DESIGN.md`, `docs/REFERENCE.md`, `docs/API-COMPATIBILITY.md`, `ROADMAP.md`, then the source of `internal/manifest`, `internal/store`, `internal/api` (snapshot/restore handlers), `internal/stamp`. Then answer A1–A6 from DESIGN.md §3 **from code and a live compose stack, not from docs**.

Deliverable: `docs/GAPS.md` containing:
- A1–A6 answers with file/line evidence and a live-stack demonstration for A1 (create SSE bucket → commit → fetch commit document from Bee directly → state exactly what the `objects` entries contain).
- The tier-B fresh-gateway runbook as tested, numbered steps (A2).
- A decision: `serve --read-only --root` vs `materialize` for v1 (with a cost argument).
- Any DESIGN.md corrections, applied.

Acceptance: every `[ASSUMED]` marker in DESIGN.md is either upgraded to `[VERIFIED]` (with evidence link) or the design branch is chosen and the dead branches marked.

**Status (2026-08-31): done except A4, which is M1 work by construction.** `docs/GAPS.md` answers A1, A2, A3, A5 and A6, with A1, A2 and A5 demonstrated on a live stack and A1 and A5 against real Swarm on a funded light node. A1 came back worse than any pre-written branch: SSE-S3 and the commit chain are mutually exclusive today — single-part SSE objects make the commit *fail* and freeze the chain, multipart SSE objects commit and publish their key-bearing references in cleartext, and a public gateway will decrypt one of those references over plain HTTPS for anyone who asks. DESIGN §5.4's SSE mandate is marked BLOCKED as a result, and `public_root` stays closed. A2's runbook is tested and shows restore carries no bucket configuration and never re-pins; A3 and A6 are answered from code; A5 confirms a light node serves the whole tier-C read path and that the data genuinely propagates. The serve-vs-materialize decision is made — read-only serve, because `store.Memory` already implements the whole interface. Output beyond the answers is a seven-item upstream list, of which one blocks this project.

## M0.5 — Upstream remedy *(s3warm PRs; runs alongside M1)*

M0's blocking findings. This milestone exists because wintercluster cannot honestly ship its recommended configuration until s3warm can commit an SSE bucket without publishing capabilities. It gates M2 onward; it does **not** gate M1, which can proceed on plaintext buckets.

Sequenced by dependency:

1. **Security response for the reference leak.** Not code: decide disclosure, since the exploit is a curl command against a public gateway and affects anyone using s3warm with SSE and multipart today. Peter's call as author; everything else here waits on nothing.
2. **SSE in the commit chain.** Descriptor indirection (following the existing `composite/1` precedent) so SSE objects are representable at all, plus encryption of the reference-bearing fields to a per-bucket recovery recipient supplied at bucket creation. Needs an upstream design discussion **before** code — it changes the on-Swarm format and the bucket-creation API. Options and the argument for this one are in `docs/GAPS.md` A1.
3. **Fail loudly on unbuildable commits.** A frozen chain is invisible from the S3 API and currently surfaces only as a warn-level log line, with the dirty flag already cleared so it is not retried. Metric at minimum.
4. **Document what the chain publishes.** Key names, sizes, ETags, batch IDs and user metadata are public for *every* bucket, not only SSE ones. s3warm's docs should say so as bluntly as they say it about deletion.
5. **`/pins` in fakebee.** Pinning silently no-ops in the dev stack, so neither snapshot pinning nor M2's re-pin fix can be tested in CI.

**Status (2026-08-31): item 2 done and open as [s3warm#1](https://github.com/petfold/s3warm/pull/1); items 1, 3, 4 done; item 5 outstanding.**

The SSE remedy is implemented on `sse-commit-chain` in s3warm and meets every acceptance criterion below, verified against a live Bee light node and the public gateway rather than only in tests. Sealing keys off the **reference**, not the object's `Encrypted` flag: the first implementation used the flag and did not close the leak, because a whole-object `UploadPartCopy` reuses the source's reference while the destination sets the flag. Two independent adversarial reviews were run; the first found four blockers including that hole, the second confirmed the reference-based sealing holds. Item 3 (loud failure) shipped as `s3warm_commit_failures_total`; item 4 (documenting what the chain publishes for every bucket) is in s3warm's REFERENCE.md. Item 5 (`/pins` in fakebee) is untouched, so **M1 still cannot assert pin coverage**.

Two consequences for this project, both from the same PR:

- The card's `bucket` section must now carry the **recovery recipient**, and the card's `sensitive` section the matching **identity** — without it a tier-B or tier-C restore of an SSE bucket cannot rebuild an index at all. This is a schema addition to DESIGN §6.1 and a new user-held secret alongside the passphrase and the Kopia password. It also means the identity is a third thing whose loss is unrecoverable; §11's custody guidance has to say so.
- Commit documents are now **version 2**. `wintercluster find` and any chain walking must read `SealedRef`, refuse versions they do not understand, and treat a v1 `parent` link as still valid.

Deferred upstream, tracked in the PR's follow-ups and worth watching because two touch this project directly:

| # | Item | Why it matters here |
|---|---|---|
| 1 | Seal once at object-write time instead of per commit | age is randomised per call, so a commit document is rewritten every commit even when the bucket has not changed. DESIGN §9's structural-sharing argument is weaker for encrypted buckets until this lands, and §9 is where the incremental-cost claim comes from |
| 2 | Rolling-upgrade hazard: a pre-v2 gateway silently builds empty references from a v2 document | A tier-B restore against an old binary would appear to succeed and produce nothing. The drill must pin the gateway version |
| 3 | Record which recipient a root was sealed to | With rotation, a card names one identity and an older root may need another. `card verify` should cross-check, which needs the chain to say |
| 4 | `sse/1` descriptor is write-only | M3's read-only serve mode is the natural consumer |
| 5 | Migration loop runs outside the advisory lock | Only bites the next migration; noted so it is not rediscovered |
| 6 | `/pins` in fakebee | M0.5 item 5, still open; gates honest pin coverage in M1 |

Acceptance:
- A bucket with default SSE on commits successfully, for single-part **and** multipart objects, and the resulting root round-trips through `?x-swarm-restore=`.
- Given a commit root of an SSE bucket and no recovery identity, no object's bytes are retrievable — verified the same way the leak was found: pull the commit document from a bare node, take every reference in it, and fetch each one from a public gateway. Every fetch must fail.
- With the recovery identity, every object *is* retrievable, and a tier-C restore of an SSE bucket produces byte-identical data.
- A commit that cannot be built is visible without reading logs.
- CI asserts a snapshot root is pinned.

## M1 — Velero-on-s3warm validation *(harness + report, minimal code)*

Build the e2e harness: kind cluster + Velero (pinned version, stock AWS plugin) + s3warm compose stack (fakebee for CI; live Bee profile for local runs). Exercise:
- Resource-only backup/restore.
- Kopia file-system backup (`defaultVolumesToFsBackup`) of a stateful workload with checksummable data; restore; byte-compare.
- `velero backup download` (presigned GET), backup deletion, backup sync from a re-pointed BSL.
- CSI snapshot data movement via csi-hostpath-driver — stretch goal; FSB is the MVP volume path.

Deliverable: `docs/COMPAT.md` — the BSL/plugin config that works (exact `s3Url`, `s3ForcePathStyle`, `checksumAlgorithm`, region), every failure found, and upstream s3warm issues filed for real bugs.

Acceptance: scripted backup→restore→verify passes against the compose stack in CI; COMPAT.md documents a clean run against a live Bee node at least once, manually.

Two constraints from M0. Until M0.5 lands, M1 runs against **plaintext buckets only** — an SSE bucket cannot commit, so any drill involving the chain is untestable in the mandated configuration; say so in COMPAT.md rather than quietly testing the wrong thing. And the harness must not claim pin coverage until fakebee grows `/pins` (M0.5 item 5).

## M2 — s3warm PRs: feed surfacing + tier-B hardening

- `x-swarm-feed-owner` / `x-swarm-feed-seq` on HeadBucket (DESIGN §12). Add `x-swarm-batch-ttl` to the same handler while it is open: per GAPS A6 it exists only on object responses today, so the agent otherwise has to HEAD an arbitrary object to learn its own retention clock.
- Re-pin on restore. `handleRestoreBucket` never pins the root it just restored, leaving it exposed to the new node's GC (GAPS A2). Two lines, and the acceptance drill below already exercises the path.
- Carry the bucket→batch binding through restore, or make the runbook re-apply it explicitly: a restored bucket silently falls back to the gateway default batch and its retention clock changes unobserved (GAPS A6).
- Fix or document everything the A2 runbook found missing in fresh-gateway `CreateBucket` + `?x-swarm-restore=<root>` (bucket config recreation, re-pinning).
- s3warm docs: a "Disaster recovery" section owning the tier-B runbook.

Acceptance: tier-B drill — populate bucket, destroy gateway + index containers, bring up fresh ones, restore by root, `velero backup get` shows the backups, restore succeeds — scripted and in s3warm's or wintercluster's CI.

## M3 — Tier C path (s3warm PR — read-only serve)

**Branch resolved by M0: `s3warm serve --read-only --root <ref>`** (in-memory index from the commit document; GET/HEAD/List only; refuses writes with a clear error). `store.Memory` already implements the full index interface and `RestoreBucket` already loads commit-document rows, so this is mostly wiring plus a write-refusal surface. `wintercluster materialize` is descoped to a documented fallback for anyone who cannot run s3warm at all — it costs local disk equal to the bucket at the worst possible moment. Cost argument in `docs/GAPS.md`. Must handle composite (multipart) descriptors and zero-byte objects (commit-document-only) correctly.

Acceptance: Velero restores a backup from the read-only endpoint with **no Postgres/SQLite anywhere** and no prior gateway state; works against a light Bee node (A5 evidence).

## M4 — wintercluster-agent MVP

Controller (Go, controller-runtime): watch Backup CRs → terminal phase → snapshot → assemble card (unsigned/unencrypted at this milestone) → sinks: Backup CR annotation, JSONL file, stdout. Prometheus metrics incl. `wintercluster_ttl_margin_seconds` + shipped alert rule. Helm chart with the deployment rules from DESIGN §5.4 (warnings included).

Acceptance: in the M1 harness, every completed backup yields a card within 60 s; `velero backup describe` shows the annotation; killing the agent mid-backup loses nothing (reconciles on restart); metrics scrape clean.

## M5 — Card cryptography, escrow, verification

- Canonical JSON + EIP-191 signing; age encryption of `sensitive` (passphrase + optional X25519 recipients); A1-branch handling of `public_root`.
- Escrow-feed sink; webhook sink.
- `wintercluster card verify` (signature, schema, feed cross-check, optional Bee existence probe), `card render` (text + QR + one-page printable), `wintercluster find`.

Acceptance: verify catches — a tampered card, a wrong signer, a card whose root is absent from the feed's chain; render output survives a print-scan-QR-decode round trip.

## M6 — Flagship drill, demo, benchmarks

- **The drill (CI):** create kind cluster + workload with known data → backup → capture card → destroy cluster, gateway, index, and the gateway's Bee node → on a clean environment with only (a new Bee node OR fakebee profile) + the card + passphrases: tier-C restore → assert byte-identical data. This is the acceptance test for the whole project.
- `demos/06-kubernetes-dr.sh` in s3warm, same tone/shape as demos 01–05.
- Benchmark harness + first honest numbers per DESIGN §9 (first-full, restore throughput, steady-state churn, resource-only time-to-restore), against a live Bee node, results committed to `docs/BENCH.md` with the exact setup.

Acceptance: drill green in CI; demo runs start-to-finish on a laptop; BENCH.md exists with methodology and at least one full matrix row.

---

## Explicit non-goals (do not drift into these)

Native Velero ObjectStore plugin; ACT-bucket support; Kasten/other tools; underwriting integration; any UI; performance optimization work beyond measuring (file findings upstream instead).
