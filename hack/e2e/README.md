# e2e harness

The M1 validation rig, and the skeleton the M6 drill grows into.

```bash
./up.sh                        # kind cluster + s3warm + velero, all pinned
./cases/01-resource-roundtrip.sh
./down.sh
```

Everything is pinned in `versions.env`; `tools.sh` fetches the toolchain into
`bin/` (gitignored) so nothing depends on what happens to be installed.

**Networking.** The gateway runs as a container on kind's own docker network,
and the BackupStorageLocation points at its IP there. Pods cannot resolve
docker container names — there is no Kubernetes DNS entry for them — so a
hostname would fail in a way that looks like an s3warm problem and is not.

**Requires** an s3warm checkout (`S3WARM_REPO`, default `../s3warm`) at
**v0.5.0 or later**: earlier releases either refuse to commit a bucket holding
encrypted objects or publish their decryption keys, so a drill against them
proves nothing.

`s3.sh` is a stdlib-only sigv4 client, so the harness needs no aws CLI or
boto3. Note that its query strings are percent-encoded before signing — a
prefix containing `/` will otherwise fail as a bare `403`.
