# Observability for agent projects

Two self-hosted observability stacks running side by side under Docker Compose on one
host, plus the local configuration that keeps them from eating the disk.

| Directory | Stack | Covers |
| --- | --- | --- |
| [`signoz/`](signoz/) | **SigNoz** | Infrastructure telemetry over OTLP: logs, traces, metrics. Deployed through Foundry. See [signoz/README.md](signoz/README.md). |
| [`opik-overlay/`](opik-overlay/) | **Opik** | LLM observability: prompt/response traces, token usage, evaluations. Upstream is cloned separately into `opik/`; this directory holds the local changes applied on top. |
| [`disk-watch.sh`](disk-watch.sh) | — | Disk watchdog, intentionally independent of both stacks. |

`opik/` and `signoz/pours/` are generated or cloned, so they are not tracked here. What is
tracked is everything needed to reproduce them.

---

## Endpoints

| Service | Address |
| --- | --- |
| SigNoz UI | http://localhost:8080 |
| SigNoz OTLP gRPC | `localhost:4317` |
| SigNoz OTLP HTTP | `http://localhost:4318` (logs at `/v1/logs`, traces at `/v1/traces`) |
| Opik UI | http://localhost:5173 |
| Opik API | `http://localhost:5173/api` |

> SigNoz does not open 4317/4318 until you create the first account in the UI. The
> collector receives its configuration over OpAMP from `signoz-signoz-0`, and OpAMP needs
> an organisation to exist first.

---

## First-time setup

Requires Docker with Compose v2, and roughly 12 GiB of RAM available for these two stacks.

### 1. SigNoz

The Foundry CLI is not committed (74 MB binary), so fetch it first:

```bash
cd signoz
mkdir -p bin
# Download foundryctl for your platform from the Foundry releases page, then:
chmod +x bin/foundryctl
```

Provide the JWT secret. It is read from `signoz/.env`, which is gitignored:

```bash
cp .env.example .env
# Put a value in SIGNOZ_JWT_SECRET, e.g.:  openssl rand -hex 32
```

Render the deployment and start it:

```bash
./bin/foundryctl forge                                   # writes pours/
ln -sfn ../../.env pours/deployment/.env                 # so Compose can read the secret
docker compose -f pours/deployment/compose.yaml up -d
```

Then open http://localhost:8080 and create the first account, which is what unlocks OTLP
ingestion.

> The symlink matters. Foundry passes `${SIGNOZ_JWT_SECRET}` through to the rendered
> compose file verbatim and Docker Compose resolves it from a `.env` sitting next to that
> file. Without the symlink Compose warns and substitutes an empty string, and SigNoz
> starts with a blank signing secret. `forge` does not delete the symlink, but recreating
> `pours/` from scratch does.

### 2. Opik

Upstream is cloned separately, because self-hosting Opik officially means cloning their
repo and running their script:

```bash
cd /home/nghiavm/workdir/observability
git clone --depth 1 --filter=blob:none --sparse https://github.com/comet-ml/opik.git
cd opik
git sparse-checkout set deployment scripts
```

A full clone is 1.2 GB - 694 MB of git history across 26,597 commits and 8,283 tags, plus
333 MB of documentation videos. The compose file pulls every image from
`ghcr.io/comet-ml/opik/`, with no `build:` anywhere, so none of the application source is
needed to run it. `deployment/` plus `opik.sh` is about 400 KB.

Apply this repository's changes, then start:

```bash
cd ..
./opik-overlay/apply.sh
cd opik && ./opik.sh
```

---

## Daily operation

### SigNoz

Run from `signoz/`; `foundryctl` writes to `./pours` by default.

```bash
./bin/foundryctl forge                                        # re-render after editing casting.yaml
docker compose -f pours/deployment/compose.yaml up -d          # apply
docker compose -f pours/deployment/compose.yaml ps
docker compose -f pours/deployment/compose.yaml logs -f signoz-signoz-0
docker compose -f pours/deployment/compose.yaml down           # stop, keep data
docker compose -f pours/deployment/compose.yaml down -v        # stop and destroy data
```

To change only one service without touching the rest:

```bash
docker compose -f pours/deployment/compose.yaml up -d --force-recreate --no-deps signoz-telemetrystore-clickhouse-0-0
```

### Opik

```bash
cd opik
./opik.sh              # start
./opik.sh --stop       # stop
./opik.sh --help
```

Or drive Compose directly, which is what `opik.sh` does underneath:

```bash
cd opik/deployment/docker-compose
docker compose -p opik-opik -f docker-compose.yaml --profile opik ps
docker compose -p opik-opik -f docker-compose.yaml --profile opik up -d
```

### Disk watchdog

```bash
./disk-watch.sh --status
```

Installed as an hourly cron job for the current user. It alerts at 75% used, or when the
observed growth rate projects the disk filling within 30 days - the two conditions catch
slow and fast failures respectively. It writes to `disk-watch.log` rather than sending
anywhere, since this host has no MTA configured.

---

## Sending telemetry

### To SigNoz, over OTLP

Any OpenTelemetry SDK or the OTel Collector works. From the host:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

From another container, either join the `signoz-network` network and use
`http://signoz-ingester-1:4318`, or use `http://host.docker.internal:4318`.

Smoke test without an SDK:

```bash
curl -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)000000000"'","severityText":"INFO","body":{"stringValue":"hello signoz"}}]}]}]}'
```

Then look under Logs in the UI, filtered to `service.name = demo`.

### To Opik, from Python

```bash
pip install opik
```

```python
import opik

opik.configure(use_local=True, url="http://localhost:5173")

@opik.track
def answer(question: str) -> str:
    ...

answer("hello")
```

Opik also integrates with LangChain, LlamaIndex, OpenAI and others; see upstream docs. For
services running in containers, point `OPIK_URL_OVERRIDE` at
`http://host.docker.internal:5173/api`.

---

## Where the data lives

Both stacks keep everything in Docker named volumes, not in this directory. Moving or
deleting this checkout does not lose data; only `docker compose down -v` does.

| Volume | Holds |
| --- | --- |
| `signoz-telemetrystore-0-0-data` | SigNoz ClickHouse: logs, traces, metrics |
| `signoz-metastore-postgres-0-data` | SigNoz metadata, users, dashboards |
| `opik-opik_clickhouse` | Opik traces and spans |
| `opik-opik_mysql` | Opik metadata |
| `opik-opik_clickhouse-config` | Opik ClickHouse config, including this repo's overlay |

---

## Local customisations for Opik

`opik/` is an upstream clone, so anything changed inside it is either untracked or at risk
of being overwritten. [`opik-overlay/`](opik-overlay/) holds those changes as tracked files
and installs them:

```bash
./opik-overlay/apply.sh            # install or update, idempotent
./opik-overlay/apply.sh --check    # report drift only, exit 1 if any
```

| Change | Installed to | Survives `git pull` in `opik/`? |
| --- | --- | --- |
| 14-day TTL on `system.*_log`, Compact parts for `metric_log` | `opik-opik_clickhouse-config` volume | yes, it lives in a volume |
| Query profiler disabled | `opik/…/clickhouse_config/users.d/zz-local-users.xml` | yes, upstream does not track it |
| 30s healthcheck, log rotation | `opik/…/docker-compose.yaml` | **no, reapply** |

Run `apply.sh --check` after upgrading Opik. Only the third row can drift.

Compose's own `docker-compose.override.yaml` mechanism does not work here: `opik.sh`
invokes Compose with `-f docker-compose.yaml` explicitly, which disables automatic
override loading, and it only adds the override file when `PORT_MAPPING=true`. That
existing override file contains nothing but port mappings, so folding these changes into
it would publish twelve ports on the host - MySQL, Redis and MinIO included - for anyone
who sets that flag.

---

## Why the configuration looks the way it does

Both ClickHouse instances carry settings that look arbitrary without context. They come
from one incident and one follow-up investigation.

**SigNoz, September 2026: 259 GB of logs in 30 days.** `system.metric_log` has 1552
columns and receives one row per second whether or not anything is being ingested.
ClickHouse decides part format in bytes but merge algorithm in rows, and the gap between
those thresholds forces Horizontal merges over Wide parts, which open one write buffer per
column - about 3.7 GiB for one merge, against a 4 GiB cap. Every merge failed and was
retried immediately, each printing a stack trace to stderr; Docker's json-file driver has
no rotation. The 1-day TTL is itself applied by a merge, so it never ran either, and parts
accumulated. Ingested user data at the time was 74 KiB.

The root cause is upstream, and the official fix
([ClickHouse#89811](https://github.com/ClickHouse/ClickHouse/pull/89811)) is absent from
the shipped config of both 25.12.5.44 and 26.3.16.16-lts. Half of that PR turns out to
have no effect, and TTL merges ignore the vertical-merge thresholds entirely, so the
working fix is to keep parts Compact rather than to force vertical merges. The reasoning
and the measurements are in the comments in [`signoz/casting.yaml`](signoz/casting.yaml)
and in `git log`.

**Opik, one day later: 12.15 GiB of `system` tables for 55.8 MiB of real traces.** A
healthcheck pinging ClickHouse every second with `wget --spider` closed the socket after
the headers, so the server lost the connection mid-body and logged two ERROR lines per
ping - 173,000 lines a day. Combined with Trace/Debug log level and no TTL on nine of
thirteen system tables, that produced 12 GiB. The query profiler contributed 4.81 GiB
more, 99.8% of it sampling idle background threads. Measured: thirty pings with `--spider`
produce 46 error lines, thirty with `-O /dev/null` produce none.

Both incidents have the same shape: a small noise source, multiplied by nothing clearing
it, multiplied by no ceiling. The remedies follow that shape - fix the source, add a TTL,
add rotation - and `disk-watch.sh` exists because 30 days passed in silence.

---

## Notes

- Resource limits in `casting.yaml` are deliberate: this host also runs customer-facing
  services that are intentionally left unlimited, so the observability stacks are the ones
  that get capped. Capping ClickHouse below its cgroup limit makes it reject work with an
  error instead of being OOM-killed, which would not promise to pick ClickHouse.
- SigNoz images use the `latest` tag for `signoz/signoz` and `signoz/signoz-otel-collector`.
  Pin them in `casting.yaml` if you want reproducible upgrades.
- `signoz/pours/` is regenerated on every `forge`. Never edit it by hand.
