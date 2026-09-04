# Observability workspace

Hai stack observability self-host, chạy song song bằng Docker Compose:

| Folder | Stack | Vai trò |
| --- | --- | --- |
| [`signoz/`](signoz/) | **SigNoz** | Logs / traces / metrics hạ tầng (OTLP). Deploy bằng Foundry — tool (`bin/foundryctl`), config (`casting.yaml`) và docs offline (`foundry/docs/`) đều nằm trong đó. Xem [signoz/README.md](signoz/README.md) |
| [`opik/`](opik/) | **Opik** | LLM observability (trace, eval). Clone nguyên repo `comet-ml/opik` — cách self-host chính thức là clone repo rồi chạy `./opik.sh` |

## Trạng thái nhanh

```bash
docker compose -f signoz/pours/deployment/compose.yaml ps   # stack SigNoz
docker compose -f opik/deployment/docker-compose/docker-compose.yaml ps  # stack Opik (hoặc cd opik && ./opik.sh)
```

## Endpoint chính

| Dịch vụ | Địa chỉ |
| --- | --- |
| SigNoz UI | http://localhost:8080 |
| SigNoz OTLP | `localhost:4317` (gRPC) / `localhost:4318` (HTTP) |
| Opik UI | http://localhost:5173 |

## Ghi chú

- Data của cả hai stack nằm trong Docker named volumes, không nằm trong folder này —
  move/xóa folder không mất data, chỉ `docker compose down -v` mới xóa.
- `signoz/casting.yaml` chứa JWT secret — repo này chỉ để local, **không push lên remote công khai**.

## Tuỳ chỉnh cục bộ cho Opik (áp lại sau khi nâng version)

`opik/` là clone riêng của upstream. Ba thay đổi dưới đây thuộc về máy này, không thuộc upstream:

| Thay đổi | Nơi đặt | Bị `git pull` ghi đè? |
|---|---|---|
| TTL 14 ngày cho `system.*_log` + settings Compact cho `metric_log` | volume `opik-opik_clickhouse-config` → `config.d/zz-local.xml` | **không** (nằm trong volume) |
| Tắt query profiler | `opik/deployment/docker-compose/clickhouse_config/users.d/zz-local-users.xml` | **không** (file untracked) |
| Healthcheck 30s + `-O /dev/null`, log rotation | `opik/deployment/docker-compose/docker-compose.yaml` | **CÓ — phải áp lại** |

Chỉ mục thứ ba cần chú ý. Sau `git pull` trong `opik/`, kiểm tra:

```bash
docker inspect opik-opik-clickhouse-1 --format '{{.Config.Healthcheck.Interval}} {{.HostConfig.LogConfig}}'
# kỳ vọng: 30000000000 và {json-file map[max-file:3 max-size:50m]}
```

Nếu về `1000000000` thì upstream đã ghi đè — áp lại phần `healthcheck` + `logging` cho service
`clickhouse` (xem `git log --all --grep=Opik` trong repo này để lấy nội dung).

Vì sao không dùng `docker-compose.override.yaml`: đã kiểm, `opik.sh` chạy với `-f docker-compose.yaml`
tường minh nên compose **không** tự nhặt override; nó chỉ được thêm khi `PORT_MAPPING=true`, và file
override hiện có chỉ chứa port mapping — nhét thay đổi vào đó sẽ kéo theo 12 port publish ra host
(gồm MySQL, Redis, MinIO) khi ai bật cờ đó.
