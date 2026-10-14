<p align="center">
  <a href="https://github.com/hitechcloud-vietnam/HiTechCloudOmnichannel" target="_blank" rel="noopener">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/assets/readme/hitechcloudomnichannel-logo-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset=".github/assets/readme/hitechcloudomnichannel-logo-light.svg">
      <img alt="HiTechCloudOmnichannel Logo" src=".github/assets/readme/hitechcloudomnichannel-logo-light.svg" width="280">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://hitechcloud.vn">Website</a>
  ·
  <a href="docs/trien-khai-production.md">Hướng dẫn production</a>
  ·
  <a href="https://github.com/hitechcloud-vietnam/HiTechCloudOmnichannel">Repo nền tảng</a>
  ·
  <a href="mailto:support@hitechcloud.vn">support@hitechcloud.vn</a>
</p>

# HiTechCloudOmnichannel — Docker Compose

Bộ triển khai Docker Compose cho **HiTechCloudOmnichannel** — nền tảng chatbot &
marketing đa kênh (Zalo, Messenger, Instagram, WhatsApp, TikTok, Telegram, Webchat…)
của HiTechCloud / Công ty CP Giải pháp Phần mềm Phố Tuệ. Repo này chạy các image
dựng sẵn trên `ghcr.io`; muốn sửa mã nguồn, hãy dùng
[repo nền tảng](https://github.com/hitechcloud-vietnam/HiTechCloudOmnichannel).

| Mục đích | Dùng |
|---|---|
| Chạy thử trên máy cá nhân | `docker compose up` (file [`docker-compose.yml`](docker-compose.yml)) |
| **Production trên một server** (HTTPS, sao lưu, nâng cấp) | [`scripts/install.sh`](scripts/install.sh) + [`docker-compose.prod.yml`](docker-compose.prod.yml) — xem **[docs/trien-khai-production.md](docs/trien-khai-production.md)** |

## Image

CI của repo nền tảng (`.github/workflows/release.yml`) đẩy 5 image
`ghcr.io/hitechcloud-vietnam/hitechcloudomnichannel-{builder,worker,realtime,mcp,javascript-executor}`:

- `:main` — mỗi lần push vào `main` (**mặc định**, `IMAGE_TAG=main`);
- `:X.Y.Z` và `:latest` — chỉ xuất hiện khi tag phát hành `vX.Y.Z` (image tag **không** có chữ `v`).

Chọn tag bằng biến `IMAGE_TAG`. Image chỉ có bản `linux/amd64`. Nếu package là
private, đăng nhập trước (token GitHub classic có scope `read:packages`):

```bash
echo '<TOKEN>' | docker login ghcr.io -u <github-username> --password-stdin
```

## Production (tóm tắt)

```bash
# DNS: DOMAIN và s3.DOMAIN trỏ về server; mở cổng 80/443
git clone https://github.com/hitechcloud-vietnam/hitechcloudomnichannel-docker-compose.git
cd hitechcloudomnichannel-docker-compose
sudo scripts/install.sh            # tạo .env + secret, pull, migrate, khởi động, HTTPS tự động
scripts/compose.sh ps              # = docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env ps
scripts/backup.sh                  # sao lưu Postgres + file + .env (đặt cron hằng đêm)
scripts/upgrade.sh 1.5.0           # sao lưu → pull → migrate → khởi động lại lần lượt
scripts/restore.sh backups/<thời-điểm>
```

Sau khi cài: đăng ký tại `https://DOMAIN/auth/sign-up` bằng `PLATFORM_ADMIN_EMAIL`
(cần SMTP để xác minh email), rồi cấu hình credentials & webhook của các kênh tại
`https://DOMAIN/admin/platform-credentials`. Chi tiết: yêu cầu server, DNS, firewall,
kênh, MCP, sao lưu, nâng cấp, xử lý sự cố —
**[docs/trien-khai-production.md](docs/trien-khai-production.md)**. Toàn bộ biến môi
trường có chú thích: [`.env.production.example`](.env.production.example).

## Chạy thử trên máy (local)

Yêu cầu: Docker Desktop / Docker Engine với Compose ≥ 2.24.4, ~4 GB RAM trống.

```bash
git clone https://github.com/hitechcloud-vietnam/hitechcloudomnichannel-docker-compose.git
cd hitechcloudomnichannel-docker-compose
# Để trình duyệt mở được URL upload/download presigned (ký trên http://filesystem:9000):
echo '127.0.0.1 filesystem' | sudo tee -a /etc/hosts
docker compose up -d
```

Đăng nhập bằng tài khoản demo được seed tự động: **demo@example.com / Demo@1234**
(chỉ ở chế độ local).

| Service | URL |
|---|---|
| Ứng dụng (qua proxy Caddy: `/ws/` → realtime, `/storage/` → RustFS) | http://localhost:3123 |
| Realtime (trực tiếp) | http://localhost:1999 |
| RustFS | http://localhost:9000 (S3 API); console http://localhost:9001 |
| MailHog (email gửi đi) | http://localhost:8025 (UI); SMTP `localhost:1025` |
| Adminer | http://localhost:8080 |
| Postgres | `localhost:5432` (user/pass `hitechcloudomnichannel` / `secretkey`) |
| Redis | `localhost:6379` |
| MCP (tuỳ chọn, `docker compose --profile mcp up -d`) | http://localhost:3333/sse |
| JavaScript executor | chỉ nội bộ — mạng Docker `internal`, chỉ `worker` gọi được |

> `docker-compose.yml` chứa secret mẫu công khai và publish cổng database — **không**
> dùng trực tiếp trên server. Production luôn dùng thêm `docker-compose.prod.yml`.

## Cấu trúc repo

```
docker-compose.yml             stack local / cơ sở cho production
docker-compose.prod.yml        override production (chỉ Caddy mở 80/443, migrate, healthcheck, giới hạn RAM, log rotation)
.env.production.example        mọi biến môi trường production, chú thích Việt + Anh
caddy/Caddyfile                reverse proxy production (HTTPS tự động)
caddy/Caddyfile.local          proxy cho stack local
caddy/sites-available/         site tuỳ chọn (mcp.caddy) — chép sang sites-enabled/ để bật
scripts/                       install.sh, backup.sh, restore.sh, upgrade.sh, compose.sh
docs/trien-khai-production.md  hướng dẫn production đầy đủ (tiếng Việt)
```

## Hỗ trợ

- Lỗi / đề xuất: [GitHub Issues](https://github.com/hitechcloud-vietnam/hitechcloudomnichannel-docker-compose/issues)
- Email: [support@hitechcloud.vn](mailto:support@hitechcloud.vn)
- Tài liệu nền tảng: thư mục [`docs/`](https://github.com/hitechcloud-vietnam/HiTechCloudOmnichannel/tree/main/docs) của repo nền tảng

---

## English summary

Docker Compose distribution of **HiTechCloudOmnichannel**, an omnichannel chatbot &
marketing platform by HiTechCloud (Pho Tue Software Solutions JSC, Vietnam). It runs
the pre-built images from `ghcr.io/hitechcloud-vietnam/hitechcloudomnichannel-*`
(`:main` on every push to main — the default `IMAGE_TAG`; `:X.Y.Z`/`:latest` only
after a `vX.Y.Z` release tag; amd64 only). Private packages require
`docker login ghcr.io` with a classic token that has `read:packages`.

- **Local trial:** `docker compose up -d`, add `127.0.0.1 filesystem` to `/etc/hosts`,
  open http://localhost:3123 and sign in as `demo@example.com` / `Demo@1234`.
  The file embeds public sample secrets — never use it alone on a server.
- **Production (single server):** point `DOMAIN` and `s3.DOMAIN` at the server, open
  ports 80/443, then run `scripts/install.sh`. It writes `.env` (secrets generated with
  `openssl`), pulls images, runs the database migrations (one-shot `migrate` service
  using the builder image's Drizzle runner) and starts the stack behind Caddy with
  automatic HTTPS. Only Caddy publishes ports. Sign up with `PLATFORM_ADMIN_EMAIL`
  (SMTP is required — sign-up needs e-mail verification) and configure channel
  credentials/webhooks under `/admin/platform-credentials`.
- **Operations:** `scripts/backup.sh` (pg_dump + storage/redis volumes + `.env`,
  rotation), `scripts/restore.sh`, `scripts/upgrade.sh <tag>` (backup → pull →
  migrate → one-by-one restart), `scripts/compose.sh` (compose wrapper).
- Full guide (Vietnamese): [docs/trien-khai-production.md](docs/trien-khai-production.md);
  every variable is documented in [`.env.production.example`](.env.production.example).
- Support: GitHub issues or [support@hitechcloud.vn](mailto:support@hitechcloud.vn).

## License

Repo này phát hành theo **[MIT License](LICENSE)**. Ứng dụng HiTechCloudOmnichannel
(xem [repo nền tảng](https://github.com/hitechcloud-vietnam/HiTechCloudOmnichannel))
cũng theo MIT, riêng các tính năng enterprise theo Commercial License.

This repository is released under the **[MIT License](LICENSE)**. The main application
is MIT-licensed as well, with enterprise features under a separate Commercial License.
