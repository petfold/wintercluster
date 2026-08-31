# wintercluster

Kubernetes disaster recovery on [Swarm](https://www.ethswarm.org/). Velero backs up your cluster to Swarm through [s3warm](https://github.com/petfold/s3warm), an S3-compatible gateway; wintercluster captures each backup's commit root into a small, signed **recovery card**, so the cluster can be restored from the bare Swarm network — no cloud account, no gateway, no metadata index, no surviving cluster.

**The whole disaster-recovery position reduces to one commit root, one feed coordinate pair, and two user-held secrets.** Small enough to print and put in a safe.

> **Status: design only. No code exists yet.**
> This repository currently holds a design and an implementation plan. Every claim below about s3warm is either marked `[VERIFIED]` against its docs or `[ASSUMED]` and gated behind milestone M0, which resolves the open questions against real code and a live stack before anything gets built. Nothing here has been measured. See [`docs/TASKS.md`](docs/TASKS.md).

## The problem

Back up a Kubernetes cluster to object storage and your recovery depends on the storage account surviving, the credentials surviving, the provider surviving, and — quietly — a metadata index surviving. Most DR plans never test the case where the backup *system* is what you lost.

Swarm changes the shape of that problem. Data written to Swarm is immutable and content-addressed: nobody, including the account owner, can delete chunks before their postage batch expires. An attacker with full credentials can wreck the *index*, but not the history. What was missing is a way to find the data afterwards — which is what wintercluster adds.

## How it works

s3warm keeps a **commit chain** per bucket: each commit is a Mantaray manifest on Swarm, with a parent link and a commit document listing every object. A commit root is therefore a complete, immutable, self-describing snapshot of the bucket — readable from any Bee node, with no gateway involved.

wintercluster does two things with that:

1. **`wintercluster-agent`** runs in the cluster, watches Velero `Backup` resources, and when one reaches a terminal phase forces a commit barrier (`PUT /{bucket}?x-swarm-snapshot=…`), captures the resulting root, and assembles a signed recovery card. Cards go to a Backup annotation, a file, a webhook, and/or an escrow feed on Swarm.
2. **`wintercluster` CLI** verifies and renders cards, finds recoverable roots from feed coordinates alone when no card survived, and drives the restore.

Card production runs *after* the backup and can never fail one — but it is never allowed to fail silently either. Every sink write is retried, surfaced in Prometheus metrics, and recorded as an Event on the Backup.

## Recovery tiers

| Tier | What you lost | Restore path |
|---|---|---|
| **A** | The cluster | Plain `velero restore`. wintercluster is not involved. |
| **B** | The gateway host too — s3warm, its index, its Bee node and pins | Fresh s3warm + any Bee node → `CreateBucket` → restore by root → `velero restore` |
| **C** | Everything, including any writable gateway | Serve the root read-only from any Bee node → point Velero at it → `velero restore` |

Tier C is the reason this project exists, and the acceptance test for all of it: *destroy the cluster, the gateway, the index, and the Bee node; restore the workload byte-identically from a hash, a passphrase, and any Bee node.* That drill is milestone M6, and it runs in CI or the project is not done.

## The recovery card

A small signed JSON document naming the bucket, the commit root, the feed coordinates to re-derive that root if the card is lost, the Velero backup it belongs to, and the postage batch TTL at capture time. Sensitive fields are [age](https://age-encryption.org)-encrypted under a recovery passphrase and any additional recipient keys you configure.

`wintercluster card render` prints it as a one-page sheet with a QR code. That printed copy is the canonical one, deliberately: everything else in this system lives on the infrastructure the card exists to recover.

**Treat cards as secrets.** They name your infrastructure, and depending on how s3warm's encrypted references interact with the commit chain — the open question M0 settles — the root itself may be a read capability for the whole bucket.

Two secrets stay with a human and are never stored by wintercluster: the card's recovery passphrase, and the Kopia repository password that decrypts volume data.

## Retention is a stamp, not a policy

Data persists on Swarm exactly as long as its postage batch is funded. So the rule is **batch TTL ≥ longest Velero backup TTL + margin**, enforced continuously rather than set once: the agent exports `wintercluster_ttl_margin_seconds` and ships an alert rule for it. A backup that quietly outlives its stamp is the one failure mode this system must never permit.

Deleting a backup does not delete the bytes. Physical chunks remain until their batch expires; deletion means letting the batch lapse, plus destroying the encryption key for server-side-encrypted objects. Plan compliance around that, not around the delete button.

## Documentation

| | |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | The design. Threat model, card schema, flows, open questions. Read the `[VERIFIED]` / `[ASSUMED]` markers. |
| [`docs/TASKS.md`](docs/TASKS.md) | Milestones M0–M6 and explicit non-goals. |
| `CLAUDE.md` | Working rules for this repository. |

Not yet written, produced by the milestones that create them: `docs/GAPS.md` (M0), `docs/COMPAT.md` (M1), `docs/BENCH.md` (M6).

## Not in scope

No native Velero plugin — using Velero's stock AWS plugin unmodified against s3warm is the entire point. No support for other backup tools, no fleet management, no UI. No performance claims until the benchmark harness produces honest numbers against a live Bee node.

## The name

A honeybee colony survives winter by forming a **winter cluster**: the bees ball around the queen and live through to spring on the stores they sealed away while it was warm. Seal the stores while it is warm; survive on them when it is not. Swarm's node software is called Bee, so the metaphor was sitting right there.

Throughout the docs and code, an unqualified "cluster" always means the Kubernetes one.
