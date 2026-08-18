#!/usr/bin/env bash
# Memasang database, aplikasi, dan jalur masuknya sebagai dua rilis Helm.
#
# Dipisah jadi dua rilis karena siklus hidupnya berbeda: objek database jarang
# berubah, rilis aplikasi diperbarui tiap versi. Dengan pemisahan ini, mencabut
# rilis aplikasi tidak ikut menghapus database.
#
# Namespace dan aturan tolak-bawaan diterapkan lebih dulu, sebelum rilis mana
# pun dibuat, supaya aturan jaringan yang salah menggagalkan pemasangan alih-alih
# lolos diam-diam.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need kind
need docker
need openssl
need helm
require_cluster

log "Namespace dan aturan tolak-bawaan"
kc apply -f "${REPO_ROOT}/k8s/app/namespace.yaml"

create_secret_once "${APP_NAMESPACE}" app-secrets \
  --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)"

# Nilainya dibaca ulang dari Secret Garage, bukan disimpan di file perantara,
# supaya kedua namespace dijamin memakai kredensial yang sama.
log "Menyalin kredensial S3 Garage ke namespace aplikasi"
garage_key="$(kc get secret garage-bootstrap -n "${GARAGE_NAMESPACE}" -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)"
garage_secret="$(kc get secret garage-bootstrap -n "${GARAGE_NAMESPACE}" -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)"
[ -n "${garage_key}" ] || fail "kredensial Garage tidak terbaca, jalankan 30-storage.sh dulu"
apply_secret "${APP_NAMESPACE}" garage-s3-credentials \
  --from-literal=ACCESS_KEY_ID="${garage_key}" \
  --from-literal=SECRET_ACCESS_KEY="${garage_secret}" \
  --from-literal=REGION=garage

# Image PostgreSQL ditarik di host lalu dimuat ke node, bukan dibiarkan ditarik sendiri oleh kubelet. 
# Tarikan di dalam cluster tidak terlihat progresnya dan bisa memakan waktu lama di jaringan yang lambat, 
# sehingga batas tunggu Cluster jadi menebak-nebak durasi unduhan alih-alih menunggu database benar-benar siap.
log "Membaca alamat API server untuk aturan egress"
read_api_server_endpoint
printf '  %s:%s\n' "${API_SERVER_ADDR}" "${API_SERVER_PORT}"

log "Menyiapkan image PostgreSQL"
postgres_image="$(helm_rendered_value database imageName: "${DATABASE_VALUES_ARGS[@]}")"
[ -n "${postgres_image}" ] || fail "imageName tidak terbaca dari chart database"
docker pull "${postgres_image}"
kind load docker-image --name "${CLUSTER_NAME}" "${postgres_image}"

log "Rilis database"
helm_release database database "${DATABASE_VALUES_ARGS[@]}"
wait_cluster_ready postgres || fail "Cluster postgres tidak mencapai Ready"

# Image dibangun lokal lalu dimuat ke node kind; tidak ada registry di jalur ini.
# Harus selesai sebelum rilis aplikasi dipasang: migrasi berjalan sebagai hook
# sebelum resource rilis diterapkan, dan hook itu memakai image stage builder.
log "Membangun image aplikasi"
docker build --target builder -t "${APP_IMAGE_BUILDER}" "${REPO_ROOT}"
docker build --target runner -t "${APP_IMAGE_RUNNER}" "${REPO_ROOT}"

log "Memuat image ke node kind"
kind load docker-image --name "${CLUSTER_NAME}" "${APP_IMAGE_BUILDER}" "${APP_IMAGE_RUNNER}"

# Isi seed datang dari berkas di repo. ConfigMap-nya dibentuk di luar chart
# karena Helm hanya bisa membaca berkas di dalam direktori chart, 
# dan menyalin data/SQL.txt ke sana akan membuat dua salinan yang bisa berbeda.
log "Menyiapkan data contoh"
kc create configmap db-seed -n "${APP_NAMESPACE}" \
  --from-file=SQL.txt="${REPO_ROOT}/data/SQL.txt" \
  --from-file=seed-user.sql="${REPO_ROOT}/k8s/app/seed-user.sql" \
  --dry-run=client -o yaml | kc apply -f -

# Migrasi dan pengisian data contoh dijalankan sebagai hook rilis ini. 
# Helm menunggu keduanya selesai, jadi tidak ada penantian Job terpisah di sini.
log "Rilis aplikasi"
helm_release app app
kc rollout status deployment/app -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}"
kc wait --for=condition=Programmed gateway/project-management -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}"

# Backup sekali jalan, diambil setelah data contoh masuk. Bukan bagian chart:
# objek Backup adalah perintah "ambil sekarang", dan hasilnya bergantung pada isi database saat itu. 
# Backup yang diambil sebelum seed menghasilkan titik pemulihan kosong, 
# sehingga uji restore membandingkan database kosong dengan sumber yang sudah terisi.
log "Backup awal"
kc apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-backup-manual
  namespace: ${APP_NAMESPACE}
spec:
  cluster:
    name: postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

log "Aplikasi terpasang"
helm --kube-context "${KUBE_CONTEXT}" list -n "${APP_NAMESPACE}"
kc get gateway -n "${APP_NAMESPACE}"
