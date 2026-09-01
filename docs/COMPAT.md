# COMPAT — Velero on s3warm

What works, what does not, and the exact configuration behind both. Milestone
M1's deliverable, and the answer to DESIGN §3's **A4**.

**Verdict: Velero's stock AWS plugin works against s3warm, unmodified, with
SSE-S3 on the bucket.** Five cases pass end to end, including a byte-identical
Kopia volume restore. Two limitations found, neither in s3warm.

## What was tested

| Component | Version |
|---|---|
| s3warm | `v0.5.0` (the floor — see below) |
| Velero | `v1.18.2` |
| `velero-plugin-for-aws` | `v1.14.2` |
| Kubernetes (kind) | `v1.37.0`, kind `v0.33.0` |
| Bee | `fakebee` from the s3warm tree (CI); live **light** node `v2.8.2` on Gnosis for the live profile |

All pinned in `hack/e2e/versions.env`. Run with `hack/e2e/up.sh` then
`hack/e2e/run-all.sh`.

## The configuration that works

```yaml
# BackupStorageLocation
provider: aws
objectStorage:
  bucket: velero
config:
  region: us-east-1          # any label; s3warm does not care, the plugin insists
  s3ForcePathStyle: "true"   # required — no virtual-host addressing
  s3Url: http://<gateway>:8333
```

Installed with `--use-volume-snapshots=false` (there is no CSI snapshotter
behind s3warm) and `--use-node-agent` (Kopia file-system backup).

Three things about this are worth stating because getting them wrong looks
like an s3warm fault:

- **`s3ForcePathStyle: "true"` is mandatory.** Virtual-host addressing would
  require per-bucket DNS.
- **`region` is a label.** It must be present and must match what the client
  signs; the value is arbitrary.
- **The gateway must be reachable from pods by an address they can resolve.**
  The harness runs the gateway on kind's docker network and points `s3Url` at
  its IP, because pods cannot resolve docker container names — there is no
  Kubernetes DNS entry for them. A hostname here fails as a connection error
  that reads like a gateway problem.

**`checksumAlgorithm` needs no override.** Velero v1.18.2 sends CRC32 by
default; s3warm records it and returns it on request
(`x-amz-checksum-crc32: wOBJiw==` observed on a backup object with
`x-amz-checksum-mode: ENABLED`). The `""` fallback some S3-compatible
gateways need is not required here.

**The BSL bucket is SSE-S3 with a recovery recipient**, per DESIGN §5.4. This
requires **s3warm ≥ v0.5.0**: earlier releases could not commit a bucket
holding encrypted objects at all, and for multipart objects published their
decryption keys into the public commit chain. Against those releases the
harness would be testing a configuration that is either broken or unsafe, so
`versions.env` names v0.5.0 as the floor.

## Cases and results

| # | Case | Result |
|---|---|---|
| 01 | Resource-only backup → destroy namespace → restore; verify values | **pass** — configmap, secret and deployment replicas all correct |
| 02 | Snapshot barrier after a completed backup (the agent's capture step, DESIGN §5.2) | **pass** — 32-byte root returned, sequence advanced, bucket head matches |
| 03 | Kopia file-system backup of 40 MiB → destroy → restore → byte-compare | **pass** — MD5 identical; 25 objects under `kopia/` |
| 04 | `velero backup download` (presigned GET), then `velero backup delete` | **pass** — valid gzip containing the expected resources; deletion clears the S3 view |
| 05 | Backup sync: drop the Backup CR, let Velero repopulate from the bucket | **pass** — re-synced in ~60 s and the resynced backup restores |

Case 04 also demonstrates the property DESIGN §4 is built on: after
`velero backup delete` removed all 9 objects from the S3 view, restoring the
bucket to a commit root captured *before* the deletion brought all 9 back. The
S3 view is mutable; the chain is not. That is simultaneously the
ransomware-resistance claim and the compliance caveat, and it is now
demonstrated rather than asserted.

Case 05 covers step 4 of the tier-B runbook (DESIGN §7.3): Velero rebuilding
its backup list from object storage alone, with the cluster's own record of its
backups destroyed.

## Limitations found

Neither is an s3warm defect; both change how the harness and the M6 drill must
be built.

**1. File-system backup silently skips hostPath volumes.** kind's default
storage class (`rancher.io/local-path`) provisions hostPath PVs, and Velero's
FSB does not back them up. The failure mode is the dangerous kind: **no
PodVolumeBackup is created, and the backup still reports `Completed`**. The
first version of case 03 passed its phase checks while capturing no volume data
at all; only the restore's checksum comparison caught it.

Consequences: case 03 uses an `emptyDir`, which exercises the same Kopia code
path; covering **PVC-backed** volumes needs a CSI driver in the cluster
(`csi-driver-host-path`), which M1 has not yet installed. And every case that
claims to test volume data must assert a completed PodVolumeBackup moving a
plausible number of bytes — a phase check alone will pass on a silent skip.
Case 03 now does.

**2. Pinning is untestable in the dev stack.** `fakebee` implements no `/pins`
endpoint, so the best-effort pin on snapshot creation silently no-ops. The
harness therefore cannot assert that a snapshot root is pinned, and must not
claim to. Tracked as M0.5 item 5.

## What remains for A4

- **CSI snapshot data movement** (`DataUpload`/`DataDownload`) — the stretch
  goal in TASKS.md M1, and untested. It matters beyond coverage: DESIGN §5.2
  assumes that at a Backup's terminal phase every object of that backup has
  landed, and with CSI data movement that depends on `DataUpload` completing
  during `Finalizing`. Verify before the agent trusts terminal phase.
- **Range GETs on composite objects under load.** Case 03 exercises them, but
  with 40 MiB and one volume, and only against fakebee — the live profile has
  so far run the resource cases, not the Kopia one. Restore throughput belongs
  to M6's benchmarks.
## The live-Bee run

`BEE_MODE=live hack/e2e/up.sh` points the gateway at a real Bee node instead of
fakebee, so backups land on Swarm proper. Run against a funded **light** node
(`v2.8.2`, Gnosis, a depth-19 batch):

- Case 01 (resource round-trip) — **pass**
- Case 02 (snapshot barrier on the encrypted bucket) — **pass**, root
  `a177199d…` returned and the head advanced

Then the tier-C read position, using only the resulting 32-byte root and the
node — no gateway, no index, no credentials (`hack/e2e/chainwalk`):

```
bucket: velero | seq: 3 | objects: 32
sealed refs: 32 | plaintext refs: 0
128-hex key-bearing strings anywhere: 0
```

So on real Swarm, a public commit root describes 32 real Velero objects and
discloses no decryption key for any of them. That is the whole point of the
s3warm v0.5.0 work, confirmed under production conditions rather than against a
model of Bee.

Two harness details cost time and are worth writing down, because both present
as gateway faults:

- **A Bee node binds its API to `127.0.0.1`.** A gateway container on a bridge
  network cannot reach it — `connection refused` via `host-gateway`. The live
  profile therefore runs the gateway on the **host** network and points the BSL
  at kind's own network gateway, which *is* the host.
- **kind's docker network is dual-stack.** Taking `IPAM.Config[0].Gateway`
  yields the IPv6 address, and an IPv6 literal in `s3Url` also needs brackets,
  which Velero's plain-string config will not carry. Select the IPv4 gateway
  explicitly.

## What remains for A4
