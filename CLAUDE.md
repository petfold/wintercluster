# CLAUDE.md — wintercluster

Kubernetes disaster recovery on Swarm. Velero backs up to Swarm through s3warm (S3-compatible gateway, `github.com/petfold/s3warm`); wintercluster captures each backup's bucket commit root into a signed **recovery card**, so a cluster can be restored from the bare Swarm network — no cloud account, no gateway, no index — with one root, feed coordinates, and two user-held secrets.

**Name.** Settled: `wintercluster` — a honeybee colony's winter survival formation, and the Kubernetes cluster that survives its own winter. Always written lowercase, one word.

**Because of that pun, "cluster" is overloaded — keep it disciplined.** Unqualified "cluster" always means the Kubernetes cluster, in docs, code, comments, and metric help strings. Never write "the cluster" to mean this project; write `wintercluster`. The card schema's `cluster` field is the Kubernetes one.

## Read first, in this order

1. `docs/DESIGN.md` — the design. Note the `[VERIFIED]` / `[ASSUMED]` markers.
2. `docs/TASKS.md` — milestones. **M0 gates all implementation.**
3. s3warm's own `docs/DESIGN.md` and `docs/REFERENCE.md` — canonical for every s3warm behavior. When this handoff and s3warm's docs disagree, s3warm's docs win; when s3warm's docs and s3warm's code disagree, the code wins and both docs get fixed.

## Ground rules

- **No implementation before M0 is done.** DESIGN.md was written from s3warm's documentation, not its code. A1 (SSE references in the commit chain) decides real design branches. Resolve it from code and a live stack, write `docs/GAPS.md`, update DESIGN.md, then build.
- **Never invent API surface.** Every s3warm endpoint, header, or flag you rely on must exist in its REFERENCE.md or in a PR you write. Same for Velero and Bee: pin versions in the harness and cite docs for behaviors you depend on (Backup phase machine, Kopia repository layout, feed resolution).
- **HTTP-only boundary.** wintercluster talks to s3warm via S3 + `x-swarm-*` extensions and to Bee via its HTTP API. Do not import s3warm packages or touch its database.
- **Two repos, clean split.** wintercluster (agent, CLI, chart, harness) is a new repo. s3warm changes are upstream PRs, small, one concern each, following that repo's conventions and updating its docs in the same PR.
- **Cards may contain capabilities.** Treat roots, cards, feed keys, and everything in `sensitive` as secrets in code, logs, tests, and fixtures. No real keys in the repo, ever.
- **The drill is the definition of done.** M6's destroy-everything-restore-from-card test is the acceptance test for the whole project. Every earlier milestone should make that drill more real, not add scope.

## Stack and conventions

- Go for agent and CLI (controller-runtime for the agent; cobra for the CLI). Helm for deployment. bash + kind + docker compose for the harness (reuse s3warm's compose stack and fakebee).
- Tests: unit tests per package; the e2e harness runs in CI from M1 on; anything touching a live Bee node also gets a fakebee-backed CI variant.
- Docs live in `docs/`; this file stays the entry point. Write plainly: short words, active voice, no filler; state limitations as bluntly as s3warm's docs do ("physical bytes remain until their batch expires" is the house style).
- Commits: imperative subject, body explains why. PRs upstream reference the wintercluster issue that motivated them.

## Layout (target)

```
wintercluster/
  README.md  CLAUDE.md  docs/{DESIGN,TASKS,GAPS,COMPAT,BENCH}.md
  cmd/wintercluster/        CLI (card verify|render, find, restore, materialize?)
  cmd/wintercluster-agent/  controller
  internal/card/            schema, canonical JSON, sign/verify, age
  internal/s3warm/          HTTP client for the x-swarm extensions
  internal/bee/             feed resolution, chain walking (read-only)
  internal/sinks/           annotation, file, webhook, escrow feed
  chart/                    Helm
  hack/e2e/                 kind + velero + s3warm harness, the M6 drill
  demos/                    staging area for the s3warm demo PR
```

## Questions for Peter (don't guess these)

- A1 outcome review before choosing the card's `public_root` default (M0 will present the evidence; the remedy in branch (b)/(c) needs his sign-off as an s3warm design change).
- Where printed-card custody guidance should live (wintercluster docs vs s3warm USER-GUIDE).
