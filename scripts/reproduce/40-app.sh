#!/usr/bin/env bash
# Memasang database, aplikasi, dan jalur masuknya.
#
# NetworkPolicy sengaja diterapkan di awal, sebelum Job dan Deployment dibuat.
# Pada pengerjaan Fase 2 policy justru dipasang terakhir, sehingga Job migrate
# kebetulan lolos dan aturan yang salah tidak ketahuan sampai jauh kemudian.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need kind
need docker
need openssl
require_cluster

log "Namespace dan NetworkPolicy aplikasi"
kc apply -f "${REPO_ROOT}/k8s/app/namespace.yaml"
kc apply -f "${REPO_ROOT}/k8s/app/networkpolicy.yaml"

create_secret_once "${APP_NAMESPACE}" app-secrets \
  --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)"

# Nilainya dibaca ulang dari Secret Garage, bukan disimpan di file perantara,
# supaya kedua namespace dijamin memakai kredensial yang sama.
log "Menyalin kredensial S3 Garage ke namespace aplikasi"
garage_key="$(kc get secret garage-bootstrap -n "${GARAGE_NAMESPACE}" -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)"
garage_secret="$(kc get secret garage-bootstrap -n "${GARAGE_NAMESPACE}" -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)"
[ -n "${garage_key}" ] || fail "kredensial Garage tidak terbaca — jalankan 30-storage.sh dulu"
apply_secret "${APP_NAMESPACE}" garage-s3-credentials \
  --from-literal=ACCESS_KEY_ID="${garage_key}" \
  --from-literal=SECRET_ACCESS_KEY="${garage_secret}" \
  --from-literal=REGION=garage

# Image PostgreSQL ditarik di host lalu dimuat ke node, bukan dibiarkan ditarik
# sendiri oleh kubelet. Tarikan di dalam cluster tidak terlihat progresnya dan
# pernah memakan 27 menit, sehingga batas tunggu Cluster jadi menebak-nebak
# durasi unduhan alih-alih menunggu database benar-benar siap.
# Versinya dibaca dari manifest supaya tidak ada versi kembar yang bisa berbeda.
log "Menyiapkan image PostgreSQL"
postgres_image="$(awk '/imageName:/ {print $2; exit}' "${REPO_ROOT}/k8s/app/cluster.yaml")"
[ -n "${postgres_image}" ] || fail "imageName tidak terbaca dari cluster.yaml"
docker pull "${postgres_image}"
kind load docker-image --name "${CLUSTER_NAME}" "${postgres_image}"

log "ObjectStore dan Cluster PostgreSQL"
kc apply -f "${REPO_ROOT}/k8s/app/objectstore.yaml"
kc apply -f "${REPO_ROOT}/k8s/app/cluster.yaml"
wait_cluster_ready postgres || fail "Cluster postgres tidak mencapai Ready"

# Image dibangun lokal lalu dimuat ke node kind; tidak ada registry di jalur ini.
log "Membangun image aplikasi"
docker build --target builder -t "${APP_IMAGE_BUILDER}" "${REPO_ROOT}"
docker build --target runner -t "${APP_IMAGE_RUNNER}" "${REPO_ROOT}"

log "Memuat image ke node kind"
kind load docker-image --name "${CLUSTER_NAME}" "${APP_IMAGE_BUILDER}" "${APP_IMAGE_RUNNER}"

# Job bersifat immutable: perubahan pada template hanya bisa diterapkan dengan
# menghapus Job lama lebih dulu.
log "Menjalankan migrasi Prisma"
kc delete job prisma-migrate -n "${APP_NAMESPACE}" --ignore-not-found
kc apply -f "${REPO_ROOT}/k8s/app/migrate-job.yaml"
wait_job "${APP_NAMESPACE}" prisma-migrate

log "Mengisi data contoh"
kc create configmap db-seed -n "${APP_NAMESPACE}" \
  --from-file=SQL.txt="${REPO_ROOT}/data/SQL.txt" \
  --from-file=seed-user.sql="${REPO_ROOT}/k8s/app/seed-user.sql" \
  --dry-run=client -o yaml | kc apply -f -
kc delete job db-seed -n "${APP_NAMESPACE}" --ignore-not-found
kc apply -f "${REPO_ROOT}/k8s/app/seed-job.yaml"
wait_job "${APP_NAMESPACE}" db-seed

log "Deployment dan Service aplikasi"
kc apply -f "${REPO_ROOT}/k8s/app/deployment.yaml"
kc apply -f "${REPO_ROOT}/k8s/app/service.yaml"
kc rollout status deployment/app -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}"

log "Gateway API"
kc apply -f "${REPO_ROOT}/k8s/app/gatewayclass.yaml"
kc apply -f "${REPO_ROOT}/k8s/app/gateway.yaml"
kc apply -f "${REPO_ROOT}/k8s/app/httproute.yaml"
kc wait --for=condition=Programmed gateway/project-management -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}"

log "HorizontalPodAutoscaler"
kc apply -f "${REPO_ROOT}/k8s/app/hpa.yaml"

log "Backup terjadwal"
kc apply -f "${REPO_ROOT}/k8s/app/backup.yaml"

log "Aplikasi terpasang"
kc get gateway -n "${APP_NAMESPACE}"
