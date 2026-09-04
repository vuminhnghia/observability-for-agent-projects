# SigNoz, self-hosted through Foundry

Docker Compose deployment generated from a single declarative file. See the
[repository README](../README.md) for first-time setup and for how the two stacks fit
together.

## Layout

| Path | Role |
| --- | --- |
| `casting.yaml` | The only file you edit. Everything else is derived from it. |
| `casting.yaml.lock` | Image versions pinned by `foundryctl`. Commit it; do not edit it. |
| `.env` | Real secrets, gitignored. Copy from `.env.example`. |
| `pours/` | Generated Compose and config files. **Never edit** - `forge` overwrites them. |
| `bin/foundryctl` | Foundry CLI, fetched from a GitHub release. Not committed (74 MB). |
| `foundry/` | Foundry source, kept only so its docs can be read offline at `foundry/docs/`. Not built or run. |

`bin/` and `foundry/` are gitignored, so a fresh checkout needs `foundryctl` downloaded
before anything works.

## Commands

Run these from this directory.

```bash
./bin/foundryctl forge                                   # render casting.yaml into pours/
./bin/foundryctl cast                                    # render and deploy in one step

docker compose -f pours/deployment/compose.yaml up -d
docker compose -f pours/deployment/compose.yaml ps
docker compose -f pours/deployment/compose.yaml logs -f signoz-signoz-0
docker compose -f pours/deployment/compose.yaml down     # stop, keep data
docker compose -f pours/deployment/compose.yaml down -v  # stop and destroy data
```

The normal edit loop is: change `casting.yaml`, run `forge`, inspect the diff in `pours/`,
then `up -d`. Reviewing the rendered output before applying is worth the extra step -
Foundry deep-merges configuration, so a change can interact with generated keys in ways
that are not obvious from `casting.yaml` alone.

To restart a single service without disturbing the others:

```bash
docker compose -f pours/deployment/compose.yaml up -d --force-recreate --no-deps signoz-telemetrystore-clickhouse-0-0
```

## Verifying a change landed

Rendered configuration is not the same as running configuration; check the server.

```bash
# ClickHouse server settings actually in effect
docker exec signoz-telemetrystore-clickhouse-0-0 clickhouse-client --query \
  "SELECT name, value FROM system.server_settings
   WHERE name IN ('max_server_memory_usage','mark_cache_size')"

# Table-level settings, for anything set through an engine definition
docker exec signoz-telemetrystore-clickhouse-0-0 clickhouse-client --query \
  "SELECT engine_full FROM system.tables WHERE database='system' AND name='metric_log'"

# Container limits and log rotation
docker inspect signoz-telemetrystore-clickhouse-0-0 \
  --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.LogConfig}}'
```

## Two traps worth knowing

**Changing a system log table's engine renames the old table.** ClickHouse keeps the
previous table as `<name>_0` with all of its data, and since that is still a live
MergeTree table, background merges continue on it. If the reason for the change was a
failing merge, the failure follows the rename. Look the names up rather than assuming:

```bash
docker exec signoz-telemetrystore-clickhouse-0-0 clickhouse-client --query \
  "SELECT name FROM system.tables WHERE database='system' AND name LIKE 'metric_log%'"
docker exec signoz-telemetrystore-clickhouse-0-0 clickhouse-client --query \
  "DROP TABLE IF EXISTS system.metric_log_0 SYNC"
```

**`engine` and `ttl` are mutually exclusive** for a system log table. Foundry generates a
`ttl` key, so adding an `engine` block leaves both present and ClickHouse refuses to start
with exit code 36. The last patch in `casting.yaml` removes the redundant key; keep it if
you keep the engine block.

## Endpoints

| Service | Address |
| --- | --- |
| UI | http://localhost:8080 |
| OTLP gRPC | `localhost:4317` |
| OTLP HTTP | `http://localhost:4318` (logs at `/v1/logs`, traces at `/v1/traces`) |

OTLP stays closed until the first account exists in the UI: the collector is configured
over OpAMP by `signoz-signoz-0`, and OpAMP needs an organisation.

## Sending telemetry

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

From another container: join the `signoz-network` network and use
`http://signoz-ingester-1:4318`, or use `http://host.docker.internal:4318`.

Smoke test:

```bash
curl -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)000000000"'","severityText":"INFO","body":{"stringValue":"hello signoz"}}]}]}]}'
```

## Resource limits

`mem_limit`, `memswap_limit` and `cpus` are Compose fields Foundry does not model, so they
go through `patches`. The ClickHouse caps inside `casting.yaml` are set below the container
limit on purpose: ClickHouse then refuses queries itself rather than being OOM-killed by
the kernel, which is important on a host shared with customer-facing services.

Total committed: 11 GiB across five containers. Raising these takes RAM away from the
unlimited services sharing the host, so prefer making a workload fit its budget over
enlarging the budget.

## Data

Everything lives in Docker named volumes (`signoz-telemetrystore-0-0-data`,
`signoz-metastore-postgres-0-data`, and others), not in this directory. Moving or deleting
this folder does not lose data; only `down -v` does.

## Notes

- `SIGNOZ_TOKENIZER_JWT_SECRET` is read from `.env` through Compose interpolation. Foundry
  passes `${SIGNOZ_JWT_SECRET}` through literally, and Compose resolves it from the `.env`
  symlinked next to the rendered compose file. If that symlink is missing, Compose warns
  and substitutes an empty string.
- `signoz/signoz` and `signoz/signoz-otel-collector` use the `latest` tag. Pin them in
  `casting.yaml` for reproducible upgrades.
- The `metric_log` engine block exists because of a merge failure that filled the disk;
  the comments in `casting.yaml` carry the measurements and the reasoning.
