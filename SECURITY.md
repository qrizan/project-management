# Security

Kontrol keamanan yang benar-benar diterapkan di proyek ini. Status ditulis apa adanya, termasuk yang belum terverifikasi penuh atau sengaja belum diperbaiki.

## Overview

| Area | Status |
| :--- | :--- |
| Secret management | Digenerate saat provisioning, tidak ada nilai produksi di version control |
| Pod isolation | Pod Security Standards `restricted` di namespace aplikasi dan database |
| Network segmentation | Default-deny per namespace, dibuka selektif, diverifikasi lewat pengujian aktif |
| Supply chain | Vulnerability gate, SBOM, image signing pada tiap build |
| Known gaps | Dua celah aplikasi belum diperbaiki (sengaja), lihat [Known Limitations](#known-limitations) |

## Secret Management

- Seluruh Secret (kredensial database, kredensial object storage, secret sesi aplikasi) dibuat oleh script provisioning dengan nilai yang di-generate saat pemasangan. Tidak ada manifest Secret maupun nilai kredensial produksi yang masuk version control.
- Dua kredensial lain punya siklus hidup berbeda: dibuat manual di luar repo (bukan di-generate script), dibaca script provisioning dari path lokal, disuntik ke cluster sebagai Secret. Deploy key SSH read-only khusus satu repo ini, dipakai Argo CD membaca chart lewat git. Personal access token GitHub scope `read:packages`, dipakai sebagai `imagePullSecret` supaya cluster bisa menarik image aplikasi yang ikut privat mengikuti visibilitas repo sumbernya. Detail alur ada di [DEVELOPMENT.md](DEVELOPMENT.md).
- Rahasia internal Garage (RPC secret, admin token) disuntik lewat environment variable, bukan file. Ini juga yang memungkinkan proses Garage berjalan sebagai user non-root tanpa masalah permission pada file rahasia.
- Satu pengecualian sadar: hash bcrypt satu akun demo ada di file konfigurasi yang di-commit, supaya hasil seed data identik tiap kali dijalankan ulang. Akibatnya kredensial demo ini permanen di riwayat repo, dan karena itu tidak dipakai di environment yang terjangkau publik.

## Pod Isolation

Namespace aplikasi dan database menegakkan Pod Security Standards level `restricted`:

- Proses berjalan non-root, dengan user ID eksplisit.
- `allowPrivilegeEscalation` dimatikan.
- Seluruh Linux capability dilepas.
- Seccomp profile default aktif.
- Filesystem root read-only.

Namespace yang menjalankan komponen observability adalah pengecualian. Komponen di dalamnya butuh akses ke namespace jaringan dan proses host untuk membaca metrik level node, kebutuhan yang dilarang eksplisit bahkan oleh level Pod Security Standards paling longgar setelah tanpa batasan sama sekali. Namespace ini karena itu tidak menegakkan Pod Security Standards sama sekali, dan tidak ada workload lain yang ditempatkan di dalamnya.

## Network Segmentation

Tiap namespace ditutup total dengan aturan default-deny untuk lalu lintas masuk maupun keluar, lalu dibuka selektif hanya untuk jalur yang dibutuhkan: aplikasi ke database, operator database ke endpoint statusnya, database ke object storage backup, resolusi DNS.

Penegakan aturan ini diverifikasi lewat pengujian aktif, bukan diasumsikan dari keberadaan manifest. Ada uji yang menyatakan lolos hanya kalau sebuah koneksi yang seharusnya diblokir memang gagal terhubung.

**Status egress tidak seragam.** Lalu lintas antar-Pod dalam satu namespace terbukti tertegakkan lewat pengujian dua arah. Beberapa tujuan di luar namespace tetap terjangkau meski aturan deny aktif, kemungkinan karena keterbatasan implementasi jaringan cluster yang dipakai di lingkungan pengembangan ini, bukan karena aturan tersebut salah tulis. Aturan yang mengizinkan jalur keluar tetap dipertahankan karena bersifat mengizinkan, bukan membatasi, sehingga mempertahankannya tidak menimbulkan risiko tambahan.

## Supply Chain

Tiap image yang dibangun di pipeline CI melewati urutan berikut sebelum sampai ke registry:

1. **Scan kerentanan.** Kerentanan tingkat kritis yang punya perbaikan tersedia menggagalkan pipeline. Cakupan scan saat ini terbatas ke tingkat kritis; tingkat keparahan lain, termasuk tinggi, tidak ikut dipindai pipeline ini.
2. **SBOM.** Daftar komponen software (format CycloneDX) dihasilkan untuk tiap image yang lolos scan.
3. **Push ke registry**, memakai token bawaan platform CI dengan izin baca-tulis dibatasi ke repository ini saja, bukan personal access token atau credential tambahan.
4. **Signing.** Image ditandatangani secara kriptografis memakai identitas OIDC dari platform CI, bukan kunci privat yang disimpan manual. Tanda tangan ini bisa diverifikasi pihak ketiga secara independen terhadap image di registry.

Image yang gagal langkah 1 tidak pernah sampai ke langkah berikutnya.

## GitOps Access Scope

Argo CD memakai AppProject `default` bawaan tanpa pembatasan: source repo, namespace tujuan, dan jenis resource cluster-scoped semuanya wildcard (`*`). Diterima apa adanya karena cluster ini cuma menjalankan satu `Application` dan Argo CD Core tidak membuat AppProject kustom. Pembatasan project baru relevan kalau ada `Application` kedua dengan kepemilikan berbeda.

## Known Limitations

| Limitation | Detail |
| :--- | :--- |
| Password hash di response API | Dua endpoint (create dan update user) mengembalikan hash password di response-nya. Temuan pada kode aplikasi yang diwariskan, di luar cakupan pekerjaan yang sedang berjalan pada proyek ini. |
| Cek role hilang di sebagian endpoint | Satu grup endpoint tidak memeriksa role administratif sebelum mengizinkan operasi tulis. Sama seperti di atas, dicatat eksplisit, belum diperbaiki. |
| Database tanpa replikasi | Tidak ada failover otomatis kalau instance database gagal. Cadangan data tetap diambil kontinu dan diverifikasi bisa dipulihkan. |
| Dependency belum sepenuhnya diaudit | Baseline audit dependency mencatat ratusan kerentanan di seluruh pohon dependency, termasuk transitif. Remediasi berjalan bertahap lewat gate pemindaian pada pipeline build, bukan sekaligus. |

Dua celah pertama di tabel di atas (password hash dan cek role) adalah temuan yang sengaja belum diperbaiki dan dicatat secara eksplisit, bukan diperbaiki diam-diam atau disembunyikan.
