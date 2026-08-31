# rootcellar — implementation plan

Rules of engagement:
- Milestones are ordered; **M0 gates everything**. No implementation code before `docs/GAPS.md` exists and DESIGN.md's `[ASSUMED]` items are resolved.
- Every milestone ends with: tests green in CI, docs updated, a one-paragraph status note appended to this file under its milestone.
- s3warm changes are PRs against `petfold/s3warm`, matching that repo's conventions (its DESIGN.md is the style reference). rootcellar code lives in its own repo.
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

## M1 — Velero-on-s3warm validation *(harness + report, minimal code)*

Build the e2e harness: kind cluster + Velero (pinned version, stock AWS plugin) + s3warm compose stack (fakebee for CI; live Bee profile for local runs). Exercise:
- Resource-only backup/restore.
- Kopia file-system backup (`defaultVolumesToFsBackup`) of a stateful workload with checksummable data; restore; byte-compare.
- `velero backup download` (presigned GET), backup deletion, backup sync from a re-pointed BSL.
- CSI snapshot data movement via csi-hostpath-driver — stretch goal; FSB is the MVP volume path.

Deliverable: `docs/COMPAT.md` — the BSL/plugin config that works (exact `s3Url`, `s3ForcePathStyle`, `checksumAlgorithm`, region), every failure found, and upstream s3warm issues filed for real bugs.

Acceptance: scripted backup→restore→verify passes against the compose stack in CI; COMPAT.md documents a clean run against a live Bee node at least once, manually.

## M2 — s3warm PRs: feed surfacing + tier-B hardening

- `x-swarm-feed-owner` / `x-swarm-feed-seq` on HeadBucket (DESIGN §12).
- Fix or document everything the A2 runbook found missing in fresh-gateway `CreateBucket` + `?x-swarm-restore=<root>` (bucket config recreation, re-pinning).
- s3warm docs: a "Disaster recovery" section owning the tier-B runbook.

Acceptance: tier-B drill — populate bucket, destroy gateway + index containers, bring up fresh ones, restore by root, `velero backup get` shows the backups, restore succeeds — scripted and in s3warm's or rootcellar's CI.

## M3 — Tier C path (s3warm PR or CLI, per M0 decision)

Either `s3warm serve --read-only --root <ref>` (in-memory index from manifest walk; GET/HEAD/List only; refuses writes with a clear error) or `rootcellar materialize`. Must handle composite (multipart) descriptors and zero-byte objects (commit-document-only) correctly.

Acceptance: Velero restores a backup from the read-only endpoint with **no Postgres/SQLite anywhere** and no prior gateway state; works against a light Bee node (A5 evidence).

## M4 — rootcellar-agent MVP

Controller (Go, controller-runtime): watch Backup CRs → terminal phase → snapshot → assemble card (unsigned/unencrypted at this milestone) → sinks: Backup CR annotation, JSONL file, stdout. Prometheus metrics incl. `rootcellar_ttl_margin_seconds` + shipped alert rule. Helm chart with the deployment rules from DESIGN §5.4 (warnings included).

Acceptance: in the M1 harness, every completed backup yields a card within 60 s; `velero backup describe` shows the annotation; killing the agent mid-backup loses nothing (reconciles on restart); metrics scrape clean.

## M5 — Card cryptography, escrow, verification

- Canonical JSON + EIP-191 signing; age encryption of `sensitive` (passphrase + optional X25519 recipients); A1-branch handling of `public_root`.
- Escrow-feed sink; webhook sink.
- `rootcellar card verify` (signature, schema, feed cross-check, optional Bee existence probe), `card render` (text + QR + one-page printable), `rootcellar find`.

Acceptance: verify catches — a tampered card, a wrong signer, a card whose root is absent from the feed's chain; render output survives a print-scan-QR-decode round trip.

## M6 — Flagship drill, demo, benchmarks

- **The drill (CI):** create kind cluster + workload with known data → backup → capture card → destroy cluster, gateway, index, and the gateway's Bee node → on a clean environment with only (a new Bee node OR fakebee profile) + the card + passphrases: tier-C restore → assert byte-identical data. This is the acceptance test for the whole project.
- `demos/06-kubernetes-dr.sh` in s3warm, same tone/shape as demos 01–05.
- Benchmark harness + first honest numbers per DESIGN §9 (first-full, restore throughput, steady-state churn, resource-only time-to-restore), against a live Bee node, results committed to `docs/BENCH.md` with the exact setup.

Acceptance: drill green in CI; demo runs start-to-finish on a laptop; BENCH.md exists with methodology and at least one full matrix row.

---

## Explicit non-goals (do not drift into these)

Native Velero ObjectStore plugin; ACT-bucket support; Kasten/other tools; underwriting integration; any UI; performance optimization work beyond measuring (file findings upstream instead).
