# Decisions

Keputusan teknis yang membentuk arsitektur proyek ini, dengan alasan dan konsekuensinya.

## Build and Runtime Use Different Base Images

Dependency di-install dan aplikasi di-build memakai bun. Container produksi menjalankan hasil build itu di atas Node.

**Rationale.** Menjalankan Next.js produksi di atas runtime bun bukan jalur yang didukung resmi oleh framework-nya. Bun dipakai sejauh yang terbukti stabil (install dependency, build), Node dipakai untuk yang menjalankan proses produksi.

**Tradeoff.** Dockerfile jadi dua base image, bukan satu image bun tunggal dari build sampai runtime. Image final tetap ramping karena stage build tidak ikut terbawa ke image produksi.

## Prisma Migrations Are Committed to Version Control

File migrasi database (`prisma/migrations`) di-commit ke repo.

**Rationale.** Migrasi database perlu urutan dan riwayat yang deterministik lintas environment. Fresh clone atau environment baru butuh riwayat migrasi yang sama persis dengan yang sudah pernah diterapkan, bukan hasil generate ulang yang bisa berbeda.

**Tradeoff.** Perubahan skema database berarti dua langkah eksplisit: mengubah `schema.prisma`, lalu men-generate dan meng-commit file migrasinya.

## Database and Application as Separate Helm Releases

Objek database (Cluster PostgreSQL, object storage backup, jadwal backup) dipasang lewat satu rilis Helm. Objek aplikasi (Deployment, Service, Gateway, autoscaler) dipasang lewat rilis lain.

**Rationale.** Siklus hidup keduanya berbeda jauh: objek database jarang berubah, objek aplikasi berubah tiap deployment. Menyatukan keduanya dalam satu rilis berarti setiap update aplikasi ikut merekonsiliasi objek database, dan mencabut rilis aplikasi berisiko ikut menghapus database beserta data-nya.

**Tradeoff.** Ada dua rilis untuk dikelola, dengan urutan pemasangan yang eksplisit (database harus siap dulu sebelum aplikasi dipasang). Sebagai imbalannya, mencabut rilis aplikasi terbukti tidak menyentuh database maupun volume datanya.

## Migration and Seed as Idempotent Helm Hooks

Migrasi skema dan pengisian data awal dijalankan sebagai Job yang di-trigger otomatis oleh siklus hidup rilis Helm (sebelum dan sesudah install/upgrade).

**Rationale.** Job Kubernetes bersifat immutable; upgrade rilis pada Job bernama sama akan ditolak tanpa mekanisme penggantian eksplisit. Menjadikannya hook membuat penggantian itu otomatis, dan menjadikannya idempoten (memeriksa keadaan sebelum bertindak) membuatnya aman dijalankan berulang tanpa efek samping.

**Tradeoff.** Sistem yang menjalankan sinkronisasi otomatis dan berulang terhadap rilis ini (seperti continuous deployment berbasis reconciliation) bisa memicu kedua hook di setiap sinkronisasi tanpa membedakan pemasangan pertama dari pembaruan biasa. Desainnya karena itu bergantung penuh pada sifat idempoten kedua Job, bukan pada asumsi urutan pemanggilan.

## Default-Deny NetworkPolicy with Label-Existence Selection

Tiap namespace ditutup total dengan aturan default-deny (ingress dan egress), lalu dibuka selektif per kebutuhan. Aturan yang menyeleksi Pod database memakai keberadaan sebuah label kunci, bukan nilai spesifiknya.

**Rationale.** Default-deny membuat celah keamanan yang tidak disengaja gagal secara eksplisit (koneksi ditolak, terlihat), bukan lolos diam-diam. Seleksi berbasis keberadaan label membuat aturan otomatis berlaku untuk instance database tambahan (misalnya untuk keperluan uji restore) tanpa perlu aturan baru ditulis tiap kali.

**Tradeoff.** Menulis manifest baru di namespace yang sama berarti secara sadar memastikan aturan default-deny yang relevan sudah mengizinkan jalur yang dibutuhkan, karena tidak ada apa pun yang terbuka secara default.

## Backup via Sidecar Plugin to Self-Hosted Object Storage

Database di-backup lewat plugin yang berjalan sebagai sidecar di Pod database, mengarsipkan write-ahead log secara kontinu ke object storage S3-compatible yang di-host sendiri di dalam cluster.

**Rationale.** Arsitektur backup berbasis plugin adalah jalur yang didukung aktif oleh operator database yang dipakai. Object storage self-hosted menghindari ketergantungan pada penyedia cloud eksternal untuk komponen yang sifatnya kritikal terhadap keberlangsungan data.

**Tradeoff.** Object storage ini sendiri jadi komponen yang perlu dijaga ketersediaannya, karena kegagalannya berarti backup berhenti tanpa aplikasi ikut terganggu, sebuah kegagalan senyap yang perlu dipantau terpisah.

## Single Database Instance, No Replication

Cluster database dijalankan dengan satu instance.

**Rationale.** Cluster Kubernetes yang dipakai berjalan di satu node fisik. Menjalankan beberapa instance database pada node yang sama menambah beban komputasi tanpa memberi redundansi nyata terhadap kegagalan node.

**Tradeoff.** Failover otomatis dan high availability database belum pernah diuji dalam sistem ini. Menambah instance untuk itu adalah perubahan konfigurasi yang bisa dilakukan kapan pun topologi cluster berubah menjadi multi-node.

## Container Images Pulled and Loaded on Host, Not at Runtime

Image database dan image aplikasi diambil (pull atau build) di mesin host, lalu dimuat langsung ke node cluster sebelum Pod yang membutuhkannya dijadwalkan.

**Rationale.** Penarikan image yang terjadi di dalam siklus hidup Pod tidak terlihat progresnya dari luar, dan durasinya bisa jauh melebihi ekspektasi pada jaringan yang lambat. Memisahkan langkah ini membuat batas waktu penantian kesiapan Pod benar-benar mengukur kesiapan aplikasi, bukan ikut menebak durasi unduhan.

**Tradeoff.** Biaya waktu unduhan tetap ada, tapi terjadi di tahap yang eksplisit dan terlihat, bukan tersembunyi di dalam status Pod yang ambigu.

## Supply Chain Security Gate on the Build Pipeline

Setiap image yang dibangun di pipeline CI dipindai kerentanannya sebelum dipublikasikan. Image dengan kerentanan tingkat kritis yang punya perbaikan tersedia menggagalkan pipeline dan tidak pernah sampai ke registry. Image yang lolos ditandatangani secara kriptografis dan disertai daftar komponen software (SBOM).

**Rationale.** Memindai sebelum publikasi mencegah image bermasalah beredar sama sekali, lebih murah daripada mendeteksi dan menarik kembali image yang sudah dipakai. Signing memberi jaminan asal-usul (provenance) yang bisa diverifikasi pihak ketiga tanpa mempercayai klaim registry begitu saja.

**Tradeoff.** Cakupan scan saat ini terbatas ke tingkat keparahan kritis; tingkat keparahan lain, termasuk tinggi, tidak ikut dipindai pipeline ini, karena jumlahnya besar dan tersebar di banyak dependency transitif yang butuh peninjauan satu per satu sebelum bisa dijadikan gate yang wajar.

## Custom Alert Rule with a Short Evaluation Window

Selain rule alert bawaan dari stack monitoring, ada satu rule kustom dengan jendela evaluasi yang sengaja dibuat pendek, ditujukan untuk membuktikan jalur alerting benar-benar berfungsi ujung ke ujung secara berulang.

**Rationale.** Rule alert bawaan yang paling relevan untuk skenario ini punya jendela evaluasi dalam hitungan belasan menit, terlalu lama untuk dipakai sebagai pemeriksaan yang ingin tetap cepat dan bisa diulang sesering mungkin.

**Tradeoff.** Rule ini murni untuk pembuktian, bukan sinyal operasional yang berarti bagi siapa pun yang memantau sistem sungguhan. Rule alert bawaan tetap aktif berdampingan dan tidak digantikan.

## Single-Source Argo CD Application, No Separate GitOps Repository

Chart aplikasi dan values yang di-bump CI berada di repo yang sama dengan source code, dibaca Argo CD lewat satu source tunggal. Tidak ada repo GitOps terpisah.

**Rationale.** Desain awal memisahkan chart (repo aplikasi) dari values (repo GitOps terpisah), dihubungkan lewat mekanisme `ref` pada Application multi-source. Kombinasi itu terbukti tidak menerapkan kredensial repo privat dengan benar pada source ber-`ref`, bug yang sudah dilaporkan ke upstream Argo CD dan belum diperbaiki per pengecekan terakhir. Satu repo menghindari jalur kode yang cacat itu sepenuhnya, tanpa melonggarkan privasi repo mana pun.

**Tradeoff.** Chart dan konfigurasi deployment-nya tidak lagi terpisah secara fisik antar repo; perubahan pada keduanya tercampur dalam riwayat commit yang sama. CI butuh izin tulis ke repo aplikasi sendiri untuk melakukan bump, bukan lagi ke repo terpisah.

## Application Image Pulled via imagePullSecrets

Node cluster menarik image aplikasi dari GHCR memakai kredensial (personal access token scope `read:packages`).

**Rationale.** Image container mengikuti visibilitas repository sumbernya di GHCR; karena repo ini privat, image-nya ikut privat secara default. Mempublikasikan package registry secara terpisah dari repo akan melonggarkan kontrol privasi yang sudah sengaja dijaga.

**Tradeoff.** Ada satu kredensial tambahan yang harus dibuat manual (GitHub tidak menyediakan cara otomatis membuat personal access token) dan disuntik ke cluster sebagai Secret, di luar mekanisme provisioning generate-otomatis yang dipakai Secret lain.

## Monitoring Namespace Runs Without Strict Pod Security Standards

Namespace yang menjalankan stack observability tidak menegakkan kebijakan keamanan Pod yang sama ketatnya dengan namespace aplikasi dan database.

**Rationale.** Komponen yang mengumpulkan metrik level node butuh akses ke namespace jaringan host, namespace proses host, dan volume yang membaca filesystem host secara langsung. Kebutuhan ini dilarang eksplisit oleh kebijakan keamanan Pod bahkan pada level yang paling longgar sebelum "tanpa batasan sama sekali".

**Tradeoff.** Namespace ini jadi satu-satunya tanpa penegakan keamanan Pod. Batasnya eksplisit: hanya komponen observability pihak ketiga yang boleh menempati namespace ini, workload lain tidak ditaruh di sini tanpa peninjauan ulang.
