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
