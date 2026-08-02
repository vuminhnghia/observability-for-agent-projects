# SigNoz self-host (Docker Compose via Foundry)

## Cấu trúc

| Đường dẫn | Vai trò |
| --- | --- |
| `casting.yaml` | File cấu hình duy nhất bạn cần sửa |
| `casting.yaml.lock` | Lock version image, do foundryctl sinh ra |
| `pours/` | Compose + config sinh tự động — **không sửa tay**, sẽ bị ghi đè |
| `bin/foundryctl` | CLI của Foundry (v0.2.17, tải từ GitHub release) |
| `foundry/` | Source repo Foundry, chỉ dùng để đọc docs offline trong `foundry/docs/` (signoz.io bị chặn trong mạng công ty) — không build/chạy |

## Lệnh thường dùng

Chạy từ thư mục `signoz/` này (foundryctl mặc định ghi output vào `./pours`):

```bash
./bin/foundryctl cast -f casting.yaml     # gauge + forge + deploy (chạy lại sau mỗi lần sửa casting.yaml)
./bin/foundryctl forge -f casting.yaml    # chỉ sinh file vào pours/, không deploy
docker compose -f pours/deployment/compose.yaml ps
docker compose -f pours/deployment/compose.yaml logs -f signoz-signoz-0
docker compose -f pours/deployment/compose.yaml down          # stop, giữ data
docker compose -f pours/deployment/compose.yaml down -v       # stop + xoá toàn bộ data
```

Data nằm trong Docker named volumes (`signoz-telemetrystore-0-0-data`, ...), không nằm
trong folder này — di chuyển/xoá folder không mất data, chỉ `down -v` mới xoá.

## Endpoint

| Dịch vụ | Địa chỉ |
| --- | --- |
| UI | http://localhost:8080 |
| OTLP gRPC | `localhost:4317` |
| OTLP HTTP | `http://localhost:4318` (logs: `/v1/logs`) |

> OTLP 4317/4318 chỉ mở sau khi bạn tạo tài khoản đầu tiên trên UI — collector nhận
> config qua OpAMP từ `signoz-signoz-0`, và OpAMP cần một org tồn tại.

## Gửi log từ service của bạn

Cách chuẩn: export OTLP từ app.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

Nếu app chạy trong container khác, dùng `http://signoz-ingester-1:4318` và join network
`signoz-network`, hoặc `http://host.docker.internal:4318`.

Test nhanh bằng curl:

```bash
curl -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"'"$(date +%s)000000000"'","severityText":"INFO","body":{"stringValue":"hello signoz"}}]}]}]}'
```

## Ghi chú

- `SIGNOZ_TOKENIZER_JWT_SECRET` được set bằng patch trong `casting.yaml`. Đừng commit
  giá trị này lên repo công khai.
- Image dùng tag `latest` cho `signoz/signoz` và `signoz/signoz-otel-collector`; pin
  version trong `casting.yaml` nếu muốn ổn định.
