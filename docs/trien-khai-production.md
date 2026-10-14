# Triển khai HiTechCloudOmnichannel production (một server)

Tài liệu này hướng dẫn tự host HiTechCloudOmnichannel trên **một server Linux** bằng
Docker Compose, với HTTPS tự động (Caddy + Let's Encrypt), sao lưu, khôi phục và
nâng cấp. Mọi lệnh chạy trong thư mục của repo này (ví dụ
`/opt/hitechcloudomnichannel-docker-compose`).

> English summary: `docs/trien-khai-production.md` is the Vietnamese production
> guide. Short version: point `DOMAIN` and `s3.DOMAIN` at the server, open
> 80/443, `docker login ghcr.io`, run `scripts/install.sh`, sign up with
> `PLATFORM_ADMIN_EMAIL`, configure channels in `/admin`, schedule
> `scripts/backup.sh`, upgrade with `scripts/upgrade.sh <tag>`.

---

## 1. Kiến trúc

```
                Internet (80/443)
                       │
                ┌──────▼──────┐   https://DOMAIN            https://S3_DOMAIN
                │    proxy    │──────────────┐              (S3 API, URL presigned)
                │   (Caddy)   │              │                     │
                └──┬───┬───┬──┘              │                     │
       /ws/*       │   │   │ /storage/public/*                     │
   ┌───────────────┘   │   └──────────────┐  │                     │
┌──▼──────┐      ┌─────▼────┐       ┌─────▼──▼────────────────────▼┐
│realtime │◄─────│ builder  │──────►│ filesystem (RustFS, S3)      │
│PartyKit │ :1999│ Next.js  │ :3000 └──────────────▲───────────────┘
└─────────┘      └──┬────┬──┘                      │
                    │    │      ┌──────────┐       │
                    │    └─────►│ postgres │◄──┐   │
                    │           │Timescale │   │   │
                    │           └──────────┘   │   │
                    │           ┌──────────┐   │   │
                    └──────────►│  redis   │◄──┤   │
                                └──────────┘   │   │
            ┌─────────────────────┐      ┌─────┴───┴┐
            │ javascript-executor │◄─────│  worker  │  (BullMQ, ~15 process)
            │ (mạng internal)     │      └──────────┘
            └─────────────────────┘
  migrate (chạy một lần trước builder/worker)      mcp (tuỳ chọn, https://MCP_DOMAIN)
```

| Service | Image | Vai trò | Public? |
|---|---|---|---|
| `proxy` | `caddy:2.10.2-alpine` | HTTPS, định tuyến | **Có** – cổng 80/443 duy nhất |
| `builder` | `…-builder:${IMAGE_TAG}` | Giao diện web, API, webhook kênh, OAuth callback | Qua proxy (`https://DOMAIN`) |
| `realtime` | `…-realtime:${IMAGE_TAG}` | WebSocket (PartyKit) | Qua proxy (`https://DOMAIN/ws/`) |
| `filesystem` | `rustfs/rustfs` | Lưu file (S3) | Qua proxy (`https://S3_DOMAIN`, `https://DOMAIN/storage/public/…` chỉ đọc) |
| `worker` | `…-worker:${IMAGE_TAG}` | Hàng đợi BullMQ (gửi tin, broadcast, AI agent, webhook…) | Không |
| `javascript-executor` | `…-javascript-executor:${IMAGE_TAG}` | Sandbox chạy JavaScript trong flow | Không (mạng `internal`, chỉ worker gọi được) |
| `postgres` | `timescale/timescaledb-ha:pg18…` | Database | Không |
| `redis` | `redis:8…-alpine` | Queue + cache (AOF, `noeviction`, có mật khẩu) | Không |
| `migrate` | `…-builder:${IMAGE_TAG}` (lệnh `migrate`) | Chạy migration Drizzle một lần | Không |
| `filesystem-init` | `rustfs/rc` | Tạo bucket, cho phép đọc ẩn danh prefix `public/` | Không |
| `mcp` (tuỳ chọn) | `…-mcp:${IMAGE_TAG}` | MCP server cho AI client | Qua proxy (`https://MCP_DOMAIN`) |

Vì sao cần **hai tên miền** (`DOMAIN` và `S3_DOMAIN`): ứng dụng ký URL presigned
(upload/download) theo `S3_ENDPOINT` và **trình duyệt dùng trực tiếp** các URL đó
(thư viện media, import danh bạ, tải file đính kèm). Vì vậy endpoint S3 phải public
và có HTTPS. Mọi request tới `S3_DOMAIN` phải có chữ ký SigV4, trừ việc đọc file
trong `public/`.

---

## 2. Yêu cầu server

| | Tối thiểu | Khuyến nghị |
|---|---|---|
| CPU | 2 vCPU | 4 vCPU trở lên |
| RAM | 4 GB (+ swap 4 GB) | 8 GB trở lên |
| Ổ đĩa | 40 GB SSD | 100 GB+ SSD (file media tăng nhanh) |
| OS | Ubuntu 22.04/24.04, Debian 12 (x86_64) | |
| Phần mềm | Docker Engine 24+, Docker Compose **≥ 2.24.4**, `openssl`, `git` | |

- Image chỉ được build cho **linux/amd64**. Server ARM (Graviton, Ampere…) sẽ phải giả
  lập và rất chậm — không khuyến nghị.
- Giới hạn RAM mặc định trong `docker-compose.prod.yml` tính cho server 8 GB; chỉnh
  bằng các biến `*_MEM_LIMIT` trong `.env`.

Cài Docker (Ubuntu/Debian):

```bash
curl -fsSL https://get.docker.com | sh
docker compose version     # phải >= 2.24.4
```

---

## 3. DNS

Tạo bản ghi **A** (và **AAAA** nếu server có IPv6) trỏ về IP public của server:

| Bản ghi | Ví dụ | Bắt buộc |
|---|---|---|
| `DOMAIN` | `chat.congty.vn` | Có |
| `S3_DOMAIN` | `s3.chat.congty.vn` | Có |
| `MCP_DOMAIN` | `mcp.chat.congty.vn` | Chỉ khi bật MCP |

Kiểm tra: `dig +short chat.congty.vn` phải ra IP của server **trước khi** khởi động,
nếu không Caddy không xin được chứng chỉ.

**Cloudflare:** để chế độ *DNS only* (đám mây xám) cho lần cấp chứng chỉ đầu tiên.
Nếu muốn bật proxy (đám mây cam), đặt SSL/TLS = *Full (strict)* và lưu ý giới hạn
upload 100 MB của Cloudflare với `S3_DOMAIN`.

---

## 4. Firewall

Chỉ cần mở SSH, 80 và 443 (TCP + UDP cho HTTP/3):

```bash
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw enable
```

Trên cloud (AWS Security Group, GCP firewall, Viettel/VNPT/FPT Cloud…) mở cùng các
cổng đó. Postgres, Redis, RustFS, builder… **không** publish cổng nào ra host trong
cấu hình production. (Lưu ý: cổng do Docker publish đi vòng qua `ufw`; ở đây chỉ có
Caddy publish 80/443 nên không bị ảnh hưởng.)

---

## 5. Quyền tải image từ GitHub Container Registry

Image được CI của repo nền tảng đẩy lên `ghcr.io/hitechcloud-vietnam/…`:

| Tag | Khi nào có |
|---|---|
| `main` | Mỗi lần push vào nhánh `main` (luôn là bản mới nhất, có thể thay đổi bất cứ lúc nào) |
| `X.Y.Z` (ví dụ `1.4.0`) | Mỗi git tag `vX.Y.Z` — **image tag không có chữ `v`** (docker/metadata-action bỏ tiền tố) |
| `latest` | Bản phát hành `vX.Y.Z` gần nhất (chỉ có sau khi đã tag release) |

Production nên **ghim `IMAGE_TAG=X.Y.Z`** khi đã có release; dùng `main` chỉ cho môi
trường thử nghiệm.

Nếu các package là private, server phải đăng nhập GHCR:

1. GitHub → *Settings* → *Developer settings* → *Personal access tokens (classic)* →
   *Generate new token*, chọn scope **`read:packages`**. Nếu organization bật SAML SSO,
   bấm *Configure SSO* → *Authorize* cho `hitechcloud-vietnam`.
2. Trên server:

   ```bash
   echo '<TOKEN>' | docker login ghcr.io -u <github-username> --password-stdin
   ```

   Thông tin đăng nhập lưu ở `~/.docker/config.json` của user chạy lệnh (thường là
   `root`). Nên dùng một tài khoản/bot chỉ có quyền đọc.

---

## 6. Cài đặt

```bash
cd /opt
git clone https://github.com/hitechcloud-vietnam/hitechcloudomnichannel-docker-compose.git
cd hitechcloudomnichannel-docker-compose
sudo scripts/install.sh
```

Script sẽ:

1. Kiểm tra Docker, Compose ≥ 2.24.4, `openssl`, RAM/ổ đĩa, cổng 80/443, DNS.
2. Tạo `.env` từ `.env.production.example` (quyền `600`), hỏi: tên miền, tên miền S3
   (mặc định `s3.<domain>`), email Let's Encrypt, email quản trị nền tảng, SMTP.
3. **Sinh secret** bằng `openssl` (chỉ khi còn trống — chạy lại script không đổi
   secret cũ): `BETTER_AUTH_SECRET` (base64 32 byte), `ENCRYPTION_KEY`,
   `REALTIME_BROADCAST_SECRET`, `JAVASCRIPT_EXECUTOR_TOKEN` (hex 32 byte),
   `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `S3_SECRET_ACCESS_KEY` (hex 24 byte).
4. `docker compose config` để kiểm tra cấu hình, `pull` image (gợi ý `docker login`
   nếu bị từ chối).
5. Khởi động Postgres/Redis/RustFS → tạo bucket → **chạy migration** → khởi động
   toàn bộ và chờ healthcheck.

Chạy không tương tác (CI, Ansible…):

```bash
scripts/install.sh --non-interactive \
  --domain chat.congty.vn --acme-email ops@congty.vn --admin-email admin@congty.vn \
  --smtp-server 'smtps://no-reply%40congty.vn:MAT_KHAU@smtp.gmail.com:465' \
  --smtp-from 'Cong Ty <no-reply@congty.vn>' --image-tag 1.4.0
```

Các tuỳ chọn khác: `--enable-mcp [--mcp-domain …]`, `--env-only` (chỉ tạo `.env`),
`--skip-pull`. Xem `scripts/install.sh --help`.

### Cài thủ công (không dùng script)

```bash
cp .env.production.example .env && chmod 600 .env
# điền DOMAIN, S3_DOMAIN, ACME_EMAIL, PLATFORM_ADMIN_EMAIL, SMTP_*, và các secret:
#   openssl rand -base64 32  -> BETTER_AUTH_SECRET
#   openssl rand -hex 32     -> ENCRYPTION_KEY, REALTIME_BROADCAST_SECRET, JAVASCRIPT_EXECUTOR_TOKEN
#   openssl rand -hex 24     -> POSTGRES_PASSWORD, REDIS_PASSWORD, S3_SECRET_ACCESS_KEY
scripts/compose.sh config -q          # kiểm tra
scripts/compose.sh pull
scripts/compose.sh up -d              # migrate + filesystem-init tự chạy trước builder/worker
scripts/compose.sh ps
```

`scripts/compose.sh` chỉ là viết tắt của
`docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env`.

### Migration database hoạt động thế nào

- Service `migrate` dùng chính image builder với lệnh `migrate`
  (`docker-entrypoint.sh migrate` → `node /app/migrate-runner/scripts/run-migrations.mjs`):
  áp dụng các migration Drizzle trong `packages/database/drizzle`, từng migration một,
  có **advisory lock** trên Postgres nên chạy song song cũng an toàn, chạy lại khi không
  có gì mới thì không làm gì.
- `builder` và `worker` chỉ khởi động sau khi `migrate` kết thúc thành công
  (`service_completed_successfully`). Trong production `RUN_DB_MIGRATE` và `RUN_DB_SEED`
  đều tắt.
- Chạy tay: `scripts/compose.sh run --rm migrate`.

---

## 7. Đăng nhập lần đầu & tài khoản quản trị

Production **không** tạo tài khoản demo. Tài khoản quản trị nền tảng là tài khoản
đăng ký bằng đúng email `PLATFORM_ADMIN_EMAIL`.

1. Mở `https://DOMAIN/auth/sign-up`, đăng ký bằng `PLATFORM_ADMIN_EMAIL`.
2. Mở email xác minh (đăng ký **bắt buộc** xác minh email, nên SMTP phải chạy được).
3. Đăng nhập, tạo workspace đầu tiên.
4. Vào `https://DOMAIN/admin` — bảng điều khiển của người vận hành nền tảng:
   *Platform credentials* (App ID/Secret của Meta, Zalo, TikTok, Google…),
   *Platform channels*, *Workspaces*; bản enterprise có thêm *Branding*,
   *Email templates*.

**Chưa có SMTP?** Có thể đánh dấu email đã xác minh bằng tay (chỉ dùng khi khẩn cấp):

```bash
scripts/compose.sh exec postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "UPDATE \"User\" SET \"emailVerified\" = true WHERE email = '"'"'admin@congty.vn'"'"'"'
```

Sau đó vẫn nên cấu hình SMTP để người dùng khác đăng ký / quên mật khẩu được.

---

## 8. Cấu hình kênh (Zalo, Messenger, Instagram, WhatsApp, TikTok, Telegram…)

Các nền tảng chỉ gửi webhook tới URL **HTTPS public**, vì vậy phải hoàn tất mục 3–6
trước. Credentials của từng kênh được nhập trong **`/admin/platform-credentials`**
(lưu trong database, mã hoá bằng `ENCRYPTION_KEY`) — không phải biến môi trường.
Mỗi thẻ trong trang đó hiển thị **chính xác** Callback URL / Webhook URL / Verify
token cần dán vào trang developer của nền tảng — luôn copy từ đó.

Dạng URL chung (với `<kênh>` dạng kebab-case: `messenger`, `instagram`,
`instagram-facebook`, `threads`, `whatsapp`, `zalo`, `tiktok`, `telegram`,
`google-sheets`, …):

| Mục đích | URL |
|---|---|
| Webhook của kênh | `https://DOMAIN/integrations/<kênh>/webhook` |
| OAuth callback của kênh | `https://DOMAIN/integrations/<kênh>/callback` |
| Đăng nhập Google / Facebook | `https://DOMAIN/api/auth/callback/google`, `…/facebook` |
| Xác minh domain Zalo | `https://DOMAIN/zalo_verifier<mã>.html` (builder tự phục vụ) |

Ghi chú theo nền tảng:

- **Meta (Messenger / Instagram / WhatsApp Cloud API):** tạo App trên
  developers.facebook.com, thêm *Valid OAuth Redirect URIs* và *Callback URL* của
  webhook như hiển thị trong `/admin`, dùng *Verify token* hiển thị ở đó. App phải ở
  chế độ *Live* để nhận webhook từ người dùng thật.
- **Zalo OA:** khai báo domain và Webhook URL trong Zalo Developers; xác minh domain
  bằng file `zalo_verifier…html` (builder phục vụ tại gốc domain).
- **TikTok, Google:** đăng ký redirect URI y như trong `/admin`.
- **Telegram:** chỉ cần bot token trong workspace; ứng dụng tự gọi `setWebhook` tới
  domain HTTPS của bạn.
- **WhatsApp gọi điện trong app (VoIP):** cần thêm TURN server (coturn) public qua
  UDP — đặt `TURN_URL`, `TURN_STATIC_SECRET` trong `.env`.
- **White-label / custom domain (enterprise):** đặt `NEXT_PUBLIC_BROKER_URL` thành một
  domain trung lập và đăng ký *duy nhất* domain đó với các nhà cung cấp OAuth/webhook.

Sau khi đổi `.env`: `scripts/compose.sh up -d` (Compose tự tạo lại container có cấu
hình thay đổi).

---

## 9. MCP server (tuỳ chọn)

Cho phép AI client (Claude, ChatGPT, Cursor…) thao tác dữ liệu workspace qua MCP.

```bash
scripts/install.sh --enable-mcp --mcp-domain mcp.chat.congty.vn
# hoặc thủ công:
#   echo 'COMPOSE_PROFILES=mcp' >> .env ; echo 'MCP_DOMAIN=mcp.chat.congty.vn' >> .env
#   cp caddy/sites-available/mcp.caddy caddy/sites-enabled/
#   scripts/compose.sh up -d
```

- Endpoint SSE: `https://MCP_DOMAIN/sse`; JSON-RPC / streamable HTTP:
  `https://MCP_DOMAIN/messages`.
- Xác thực bằng **workspace API token** (Settings → Developer → API Keys) qua
  `?workspace_token=…` hoặc header `x-workspace-token`.
- MCP server đọc OpenAPI spec từ builder nội bộ (`http://builder:3000/api/public-spec.json`).
- Hạn chế origin trình duyệt bằng `MCP_CORS_ORIGIN` nếu cần.

---

## 10. Sao lưu

```bash
scripts/backup.sh                       # -> backups/YYYYmmdd-HHMMSS/
scripts/backup.sh --dir /mnt/backup --retention-days 14
scripts/backup.sh --no-files            # chỉ database + .env
scripts/backup.sh --stop-storage        # dừng redis/RustFS/worker vài giây để copy nhất quán tuyệt đối
```

Mỗi bản sao lưu gồm `postgres.dump` (pg_dump định dạng custom, có kiểm tra đọc lại),
`filesystem-data.tar.gz` (toàn bộ file đã upload), `redis-data.tar.gz` (hàng đợi),
`env` (bản sao `.env` — **chứa secret**), `MANIFEST`, `SHA256SUMS`. Bản cũ hơn
`BACKUP_RETENTION_DAYS` ngày (mặc định 7) bị xoá tự động.

Lịch tự động (cron của root, 02:30 hằng đêm):

```bash
crontab -e
30 2 * * * cd /opt/hitechcloudomnichannel-docker-compose && scripts/backup.sh >> backups/backup.log 2>&1
```

**Đưa bản sao lưu ra khỏi server** (bắt buộc với production), ví dụ:

```bash
rclone sync /opt/hitechcloudomnichannel-docker-compose/backups remote:hitechcloud-backups
# hoặc
rsync -a --delete backups/ backup@nas.congty.vn:/backups/hitechcloudomnichannel/
```

> **Quan trọng:** mất `ENCRYPTION_KEY` thì toàn bộ token kênh, API key đã lưu không
> giải mã được nữa. Giữ một bản `.env` ở nơi an toàn (password manager, vault).

Định kỳ thử khôi phục lên một server phụ để chắc chắn bản sao lưu dùng được.

---

## 11. Khôi phục

```bash
scripts/restore.sh backups/20261014-023000            # trên server hiện tại
scripts/restore.sh /path/20261014-023000 --with-env   # server mới (dùng .env trong bản sao lưu)
```

Script kiểm tra `SHA256SUMS`, cảnh báo nếu `ENCRYPTION_KEY` khác nhau, dừng ứng
dụng, tạo lại database và `pg_restore` với `timescaledb_pre_restore()` /
`timescaledb_post_restore()`, thay nội dung volume RustFS và Redis, rồi khởi động lại
(service `migrate` sẽ nâng schema nếu bản sao lưu cũ hơn image đang chạy).
Tuỳ chọn: `--skip-files`, `--skip-db`, `--yes`.

Chuyển sang server mới: cài Docker + `docker login ghcr.io` → clone repo → chép thư
mục backup sang → `scripts/restore.sh <dir> --with-env --yes` → trỏ DNS sang IP mới.

---

## 12. Nâng cấp

```bash
scripts/upgrade.sh 1.5.0      # lên bản phát hành 1.5.0 (git tag v1.5.0)
scripts/upgrade.sh            # pull lại tag hiện tại (ví dụ main)
scripts/upgrade.sh 1.5.0 --prune --yes
```

Trình tự: sao lưu → đặt `IMAGE_TAG` → `pull` → `migrate` → khởi động lại lần lượt
`javascript-executor` → `realtime` → `worker` (chờ job đang chạy tối đa 60 giây) →
`builder` → `mcp` → `proxy`, mỗi bước chờ healthcheck. Nếu `pull` hoặc `migrate`
thất bại, `IMAGE_TAG` được trả về giá trị cũ và container đang chạy không bị đụng tới.

Quay lại bản cũ: `scripts/upgrade.sh <tag-cũ> --skip-backup`. Nếu migration của bản
mới không tương thích ngược, khôi phục bản sao lưu vừa tạo (`scripts/restore.sh`).

Với một server duy nhất, mỗi service có một bản sao nên có vài giây gián đoạn khi
`builder`/`realtime` khởi động lại (trình duyệt tự kết nối lại WebSocket).

Cập nhật chính repo này (compose, Caddyfile, script): `git pull` rồi
`scripts/compose.sh up -d`.

---

## 13. Vận hành hằng ngày & log

```bash
scripts/compose.sh ps                                  # trạng thái + health
scripts/compose.sh logs -f --tail=200 builder worker   # log ứng dụng
scripts/compose.sh logs --since=1h proxy               # access log (JSON) + chứng chỉ
scripts/compose.sh logs migrate                        # kết quả migration gần nhất
scripts/compose.sh restart worker
docker stats                                           # CPU/RAM từng container
```

- Log container được xoay vòng (20 MB × 5 file mỗi container).
- Mức log: `LOG_LEVEL=info` (đổi sang `debug` tạm thời khi điều tra).
- Vào database: `scripts/compose.sh exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'`.
- Redis: `scripts/compose.sh exec redis redis-cli info memory` (mật khẩu lấy từ
  `REDISCLI_AUTH` sẵn trong container).

---

## 14. Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp / cách xử lý |
|---|---|
| `pull` báo `denied` / `unauthorized` | Chưa `docker login ghcr.io` hoặc token thiếu `read:packages` / chưa authorize SSO (mục 5). Kiểm tra `IMAGE_TAG` có tồn tại (tag phát hành không có chữ `v`). |
| `docker compose config` báo `set XXX in .env` | Thiếu biến bắt buộc trong `.env`. |
| Lỗi `!reset` / `!override` khi chạy compose | Docker Compose quá cũ, cần ≥ 2.24.4. |
| Trình duyệt báo lỗi chứng chỉ / Caddy không lấy được cert | DNS chưa trỏ đúng, cổng 80/443 bị chặn hoặc đang bị nginx/apache chiếm, bật proxy Cloudflare quá sớm. Xem `scripts/compose.sh logs proxy`. Let's Encrypt giới hạn số lần cấp — sửa xong rồi mới khởi động lại nhiều lần. |
| `builder` unhealthy, log có `Invalid environment variables` | Một biến sai định dạng (ví dụ `ENCRYPTION_KEY` không đủ 64 hex, secret < 32 ký tự, biến số để rỗng `KEY=`). Comment dòng tuỳ chọn thay vì để trống. |
| `builder`/`worker` không khởi động, `migrate` exited 1 | Xem `scripts/compose.sh logs migrate`. Sửa nguyên nhân rồi `scripts/compose.sh run --rm migrate`. |
| Upload file lỗi / ảnh không hiển thị | `S3_DOMAIN` chưa có DNS/cert; kiểm tra `https://S3_DOMAIN/health`. File public phục vụ ở `https://DOMAIN/storage/public/…`. Xem `scripts/compose.sh logs filesystem filesystem-init`. |
| Tin nhắn không cập nhật realtime | Kiểm tra `https://DOMAIN/ws/` đi tới `realtime` (`logs realtime`), `REALTIME_BROADCAST_SECRET` khớp giữa các service (đều lấy từ `.env`). |
| Không nhận được email đăng ký | Sai `SMTP_SERVER` (ký tự đặc biệt trong mật khẩu phải URL-encode, ví dụ `@` → `%40`), nhà cung cấp chặn cổng 25/465/587. Xem log `builder`. |
| Kênh không nhận webhook | URL webhook/callback trên trang developer không khớp `/admin/platform-credentials`; app Meta chưa *Live*; domain chưa có HTTPS hợp lệ. Xem `logs builder` (bật `LOG_DEBUG=true` tạm thời để log body webhook đã che dữ liệu). |
| Job flow JavaScript lỗi | `scripts/compose.sh logs javascript-executor worker`; `JAVASCRIPT_EXECUTOR_TOKEN` ≥ 32 ký tự. |
| Hết RAM / container bị OOM-kill | `docker stats`, tăng RAM server hoặc chỉnh `*_MEM_LIMIT`, `WORKER_NODE_OPTIONS`. |
| Đầy ổ đĩa | `docker system df`, `scripts/upgrade.sh --prune`, giảm `BACKUP_RETENTION_DAYS`, chuyển backup ra ngoài. |
| Đổi mật khẩu Postgres | `POSTGRES_PASSWORD` chỉ áp dụng lần khởi tạo đầu. Đổi bằng `ALTER USER … PASSWORD '…'` trong psql rồi cập nhật `.env` và `scripts/compose.sh up -d`. |

---

## 15. Checklist bảo mật

- [ ] `.env` quyền `600`, không commit lên git (đã có trong `.gitignore`).
- [ ] Mọi secret được sinh ngẫu nhiên (không dùng giá trị mẫu của `docker-compose.yml`).
- [ ] Chỉ mở 22/80/443; SSH dùng key, tắt đăng nhập bằng mật khẩu.
- [ ] `IMAGE_TAG` ghim theo bản phát hành.
- [ ] Sao lưu chạy hằng đêm và được chép ra ngoài server; đã thử khôi phục.
- [ ] SMTP dùng tài khoản riêng / app password.
- [ ] Token GHCR chỉ có quyền `read:packages`.
- [ ] Cập nhật OS và Docker định kỳ (`unattended-upgrades`).

---

## Phụ lục A — Định tuyến của Caddy (`caddy/Caddyfile`)

| Host / đường dẫn | Đích | Ghi chú |
|---|---|---|
| `DOMAIN/ws/*` | `realtime:1999` (bỏ tiền tố `/ws`) | WebSocket PartyKit (`/ws/parties/<party>/<room>`) |
| `DOMAIN/storage/public/*`, `DOMAIN/assets/public/*` | `filesystem:9000/<S3_BUCKET>/public/*` | Chỉ GET/HEAD, bỏ query string |
| `DOMAIN/*` | `builder:3000` | UI, API, webhook, OAuth |
| `S3_DOMAIN/*` | `filesystem:9000` | S3 API; chặn liệt kê bucket không ký; CORS cho upload từ trình duyệt |
| `MCP_DOMAIN/*` | `mcp:3333` | Chỉ khi bật `caddy/sites-enabled/mcp.caddy` |

Bên trong mạng Docker, `DOMAIN` và `S3_DOMAIN` được alias về container `proxy`, nên
các lời gọi server-side (S3 SDK, URL presigned) không phải đi ra Internet.

## Phụ lục B — Biến môi trường

Danh sách đầy đủ, có chú thích và nguồn gốc trong repo nền tảng: xem
[`.env.production.example`](../.env.production.example). Các giá trị được **tự tính**
trong `docker-compose.prod.yml` (không đặt trong `.env`): `DATABASE_URL`,
`REDIS_URL`, `BETTER_AUTH_URL`, `NEXT_PUBLIC_BUILDER_URL`,
`NEXT_PUBLIC_INTERNAL_STORAGE_URL`, `FORCE_PUBLIC_HTTPS=true`, `S3_ENDPOINT`
(mặc định `https://S3_DOMAIN`), `REALTIME_INTERNAL_URL`, `JAVASCRIPT_EXECUTOR_URL`,
`NODE_ENV=production`, `RUN_DB_MIGRATE=false`, `RUN_DB_SEED=false`.
