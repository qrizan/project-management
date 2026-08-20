## Project Management App

Aplikasi manajemen proyek/tugas (Next.js App Router + Prisma + PostgreSQL), dengan tampilan Tailwind/Flowbite React, di-orkestrasi di atas Kubernetes lewat Helm, CI/CD, dan observability.

Dokumen lain di repo ini: [ARCHITECTURE.md](ARCHITECTURE.md) untuk bentuk teknis sistem, [DECISION.md](DECISION.md) untuk keputusan desain dan alasannya, [SECURITY.md](SECURITY.md) untuk kontrol keamanan yang diterapkan.

### Built with

| Tool      | Link                        |
| :-------- | :-------------------------- |
| Next.js   | https://nextjs.org          |
| Prisma    | https://www.prisma.io       |
| Flowbite  | https://flowbite-react.com  |
| Puppeteer | https://pptr.dev            |

### Users diagram

![users-diagram](screenshots/users-diagram.png)

## Repository structure

```
.
├── app/                    # Next.js App Router: pages, API routes, components
├── prisma/                 # schema, migrations, Prisma client singleton
├── data/                   # seed data (SQL.txt)
├── Dockerfile              # multi-stage build: deps -> builder -> runner
├── docker-compose.yml      # local dev stack (app, db, migrate)
│
├── k8s/                    # cluster and platform manifests (not app releases)
│   ├── kind-cluster.yaml   # local kind cluster definition
│   ├── platform/           # GatewayClass, metrics-server
│   ├── garage/             # object storage (S3-compatible) for backup
│   ├── app/                # namespace baseline, restore test cluster, seed SQL
│   └── observability/      # monitoring namespace, kube-prometheus-stack values, alert rule
│
├── charts/                 # Helm charts, installed as two separate releases
│   ├── database/           # PostgreSQL Cluster, ObjectStore, ScheduledBackup
│   └── app/                # Deployment, Service, Gateway, HPA, migrate/seed hooks
│
├── scripts/reproduce/      # rebuild the whole stack from an empty cluster
│   ├── run-all.sh          # runs every stage below in order
│   ├── 00-teardown.sh
│   ├── 10-cluster.sh
│   ├── 20-platform.sh
│   ├── 30-storage.sh
│   ├── 40-app.sh
│   ├── 45-helm-lifecycle.sh
│   ├── 47-observability.sh
│   ├── 48-alert-drill.sh
│   ├── 50-verify.sh
│   └── 60-restore-drill.sh
│
└── .github/workflows/ci.yml  # lint, typecheck, build, scan, sign, push
```

## Application setup

### Requirements

- bun 1.3.14
- PostgreSQL, reachable via `DATABASE_URL`

### Install dependencies

```
bun install
```

### Copy .env

```
cp .env.example .env
```

### Database (PostgreSQL)

Contoh menjalankan PostgreSQL lokal lewat Docker:

```
docker run -d --name pg-project-management \
  -e POSTGRES_USER=johndoe \
  -e POSTGRES_PASSWORD=randompassword \
  -e POSTGRES_DB=mydb \
  -p 5432:5432 \
  postgres:16
```

Sesuaikan `DATABASE_URL` di `.env` dengan kredensial yang dipakai.

### Generate NEXTAUTH_SECRET

```
openssl rand -base64 32
```

### .env configuration

```
DATABASE_URL="postgresql://johndoe:randompassword@localhost:5432/mydb?schema=public"
NEXTAUTH_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Database migration

```
bunx prisma generate
bunx prisma migrate dev --name init
```

### Data example

Lihat `data/SQL.txt`.

### Running

```
bun --watch run dev
```

### UI testing and screenshots

Skrip Puppeteer di `scripts/test.ts`, login ke `http://localhost:3000` lalu men-screenshot tiap halaman.

```
mkdir -p screenshots/test
bunx ts-node scripts/test.ts
```

### Screenshots

![dashboard](screenshots/dashboard.png)

![projects-list](screenshots/projects-list.png)

![project-detail](screenshots/project-detail.png)

## Orchestration setup (kind)

Manifest cluster dan platform ada di `k8s/`; database dan aplikasi dipasang sebagai dua Helm release terpisah dari `charts/`; observability lewat rilis Helm pihak ketiga. Detail lengkap arsitekturnya ada di [ARCHITECTURE.md](ARCHITECTURE.md).

### Requirements

- kind, kubectl, helm, docker, openssl, curl

### Running

```
scripts/reproduce/run-all.sh --clean
```
atau
```
scripts/reproduce/run-all.sh --clean 2>&1 | tee scripts/reproduce/output.txt
```

Menghapus cluster kind sebelumnya (kalau ada), membangun cluster baru, memasang seluruh komponen platform (cert-manager, CloudNativePG, Envoy Gateway, metrics-server), object storage backup, database dan aplikasi, lalu observability (Prometheus/Grafana/Alertmanager). Ditutup dengan pemeriksaan otomatis: kesehatan Pod, penegakan NetworkPolicy, jalur HTTP lewat Gateway, alert yang bisa dipicu, dan uji restore backup.

Prosesnya memakan waktu lama, sebagian besar untuk menarik image.

Tiap tahap juga bisa dijalankan sendiri; urutannya mengikuti awalan angka pada nama file.

### Cleanup

```
scripts/reproduce/00-teardown.sh
```

Menghapus cluster kind, container `cloud-provider-kind`, dan container LoadBalancer sisa (`kindccm-*`). Aman dijalankan walau tidak ada apa-apa untuk dihapus.

Image yang ditarik atau dibangun ke host selama reproduce sengaja tidak ikut terhapus, supaya jalan berikutnya tidak menarik ulang dari jaringan. Untuk melepas ruang disk sepenuhnya, misalnya sebelum eksperimen lain yang tidak berhubungan:

```
docker rmi project-management-app:builder project-management-app:runner
docker buildx prune -f
```

Perintah kedua menghapus build cache Docker, bukan cuma image proyek ini; image dari eksperimen lain yang belum dipakai juga ikut terhapus.

## CI/CD

Setiap push ke `main` menjalankan lint, typecheck, build image, scan kerentanan (gate blocking pada temuan critical), generate SBOM, push ke GitHub Container Registry, dan signing image dengan cosign keyless. Lihat `.github/workflows/ci.yml`.
