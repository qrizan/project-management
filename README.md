## Project Management App

#### built with

| Tools     |                            |
| :-------- | :------------------------- |
| NextJS    | https://nextjs.org         |
| Prisma    | https://www.prisma.io      |
| Flowbite  | https://flowbite-react.com |
| Puppeteer | https://pptr.dev           |

#### users diagram

![users-diagram](screenshots/users-diagram.png)

## setup

#### requirements

- bun 1.3.14
- PostgreSQL yang bisa diakses lewat `DATABASE_URL`

#### install dependencies

```
bun install
```

#### copy .env

```
cp .env.example .env
```

#### database (PostgreSQL)

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

#### generate NEXTAUTH_SECRET

```
openssl rand -base64 32
```

#### .env configuration

```
DATABASE_URL="postgresql://johndoe:randompassword@localhost:5432/mydb?schema=public"
NEXTAUTH_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

#### database migration

```
bunx prisma generate
```

```
bunx prisma migrate dev --name init
```

#### data example

> data/SQL.txt

#### running

```
bun --watch run dev
```

#### UI testing and generate screenshots

> scripts/test.ts

```
...
const targetUrl = 'http://localhost:3000';
const widthResolution = 1280;
const heightResolution = 960;
...
```

```
mkdir -p screenshots/test
bunx ts-node scripts/test.ts
```

#### screenshots

![dashboard](screenshots/dashboard.png)

![projects-list](screenshots/projects-list.png)

![project-detail](screenshots/project-detail.png)
