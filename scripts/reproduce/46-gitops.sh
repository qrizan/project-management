#!/usr/bin/env bash
# Install Argo CD (Core mode). Application single-source mengambil alih sync
# rilis app: chart dan values sama-sama dari repo ini (charts/app/values.yaml
# + charts/app/values-deploy.yaml), dibaca lewat deploy key read-only.
#
# Harus jalan setelah 40-app.sh dan 45-helm-lifecycle.sh, bukan sebelumnya.
# 40-app.sh masih memasang app sebagai rilis Helm langsung.
# 45 menguji uninstall/reinstall app tanpa menyentuh database, itu harus
# selesai duluan. Kalau dibalik, selfHeal langsung memasang ulang rilis yang
# sengaja di-uninstall untuk pengujian itu.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
require_cluster

# Dibuat manual sekali di luar reproduce, stabil lintas run.
# Beda dari Secret lain di script ini yang selalu di-generate ulang.
# Path lewat env var, default sesuai path yang dipakai saat key ini dibuat.
ARGOCD_REPO_KEY_PATH="${ARGOCD_REPO_KEY_PATH:-${HOME}/.ssh/pm-argocd-readonly}"
[ -f "${ARGOCD_REPO_KEY_PATH}" ] \
  || fail "deploy key tidak ditemukan di ${ARGOCD_REPO_KEY_PATH}, buat SSH deploy key read-only untuk repo ini di path tersebut"

# GitHub tidak punya cara otomatis membuat personal access token, jadi ini
# dibuat manual sekali di luar reproduce, sama seperti deploy key di atas.
# Scope read:packages saja - image ghcr.io/qrizan/project-management ikut
# privat mengikuti repo sumbernya, dan ini satu-satunya kredensial yang
# dibutuhkan node cluster untuk pull-nya.
GHCR_PULL_TOKEN_PATH="${GHCR_PULL_TOKEN_PATH:-${HOME}/.ghcr-pull-token}"
[ -f "${GHCR_PULL_TOKEN_PATH}" ] \
  || fail "token GHCR tidak ditemukan di ${GHCR_PULL_TOKEN_PATH}, buat personal access token GitHub scope read:packages di path tersebut"

log "Namespace argocd"
kc create namespace argocd --dry-run=client -o yaml | kc apply -f -

# core-install.yaml tidak tersedia sebagai release asset, beda dari
# cert-manager/CNPG/Barman di 20-platform.sh (dicek langsung ke daftar asset
# rilis, cuma ada binary CLI dan SBOM).
# raw.githubusercontent.com jadi satu-satunya sumber, dibungkus retry untuk
# rate-limit yang sama.
log "Argo CD Core ${ARGOCD_VERSION}"
# --server-side, bukan client-side (default): client-side apply menyimpan
# seluruh konfigurasi di annotation kubectl.kubernetes.io/last-applied-configuration,
# dan CRD applicationsets.argoproj.io di sini melebihi batas 262144 byte
# metadata.annotations. Pola yang sama dengan CRD CloudNativePG di
# 20-platform.sh.
retry 5 15 kc apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"

# Core install: 4 workload (application-controller = StatefulSet;
# applicationset-controller, repo-server, redis = Deployment).
# Dipoll sebagai jumlah Pod Ready di namespace, sama seperti
# kube-prometheus-stack di 47-observability.sh. Tidak perlu tahu persis
# kind/nama tiap komponen.
# kubectl wait tidak dipakai: tidak mengeluarkan progres, penantian panjang
# tidak bisa dibedakan dari macet.
log "Menunggu komponen Argo CD Core siap"
deadline=$(( SECONDS + WAIT_LONG_SECS ))
while true; do
  total="$(kc get pods -n argocd --no-headers 2>/dev/null | wc -l)"
  not_ready="$(kc get pods -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "True" { printf "%s ", $1 }')"
  if [ "${total}" -ge 4 ] && [ -z "${not_ready}" ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    fail "Pod Argo CD belum Ready setelah ${WAIT_LONG}: ${not_ready}"
  fi
  printf '  ... belum Ready (%s/4 Pod ada): %s\n' "${total}" "${not_ready:-menunggu Pod muncul}"
  sleep 15
done

# API server Argo CD biasanya membuat AppProject "default" otomatis saat
# start. Core mode tidak punya API server, jadi harus diterapkan manual di
# sini, sebelum Application yang menyebut project: default dibuat.
log "AppProject default"
kc apply -f "${REPO_ROOT}/k8s/gitops/appproject-default.yaml"

# Secret bertipe "repository" (per-repo, exact match dengan repoURL di
# application.yaml), dipakai argocd-repo-server untuk autentikasi git saat
# membaca chart dan values.
log "Kredensial pull image GHCR"
kc create secret docker-registry ghcr-pull-secret -n "${APP_NAMESPACE}" \
  --docker-server=ghcr.io \
  --docker-username=qrizan \
  --docker-password="$(cat "${GHCR_PULL_TOKEN_PATH}")" \
  --docker-email=ghcr-pull@users.noreply.github.com \
  --dry-run=client -o yaml | kc apply -f -

log "Kredensial baca repo project-management"
kc create secret generic project-management-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:qrizan/project-management.git \
  --from-file=sshPrivateKey="${ARGOCD_REPO_KEY_PATH}" \
  --dry-run=client -o yaml \
  | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kc apply -f -

log "Application (single-source, sync otomatis + selfHeal)"
kc apply -f "${REPO_ROOT}/k8s/gitops/application.yaml"

log "Menunggu Application Synced dan Healthy"
deadline=$(( SECONDS + WAIT_LONG_SECS ))
while true; do
  sync_status="$(kc get application project-management-app -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kc get application project-management-app -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [ "${sync_status}" = "Synced" ] && [ "${health_status}" = "Healthy" ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    fail "Application belum Synced+Healthy setelah ${WAIT_LONG} (sync=${sync_status:-?}, health=${health_status:-?})"
  fi
  printf '  ... sync=%s health=%s\n' "${sync_status:-belum ada status}" "${health_status:-belum ada status}"
  sleep 15
done

# Instalasi selesai di titik ini. Pemeriksaan di bawah pakai
# pass/bad/check_eq (terkumpul, dilaporkan di Ringkasan).
# Pola yang sama dengan 45-helm-lifecycle.sh, karena keduanya menguji
# perpindahan state, bukan cuma bentuk manifest.
log "Verifikasi: image Pod app berasal dari GHCR, bukan build lokal"
app_image="$(kc get deployment app -n "${APP_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
case "${app_image}" in
  ghcr.io/qrizan/project-management@sha256:*) pass "image app: ${app_image}" ;;
  *) bad "image app bukan dari GHCR: ${app_image}" ;;
esac

log "Verifikasi: selfHeal mengembalikan drift manual"
declared_cpu="$(kc get deployment app -n "${APP_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')"
kc patch deployment app -n "${APP_NAMESPACE}" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"300m"}]' \
  >/dev/null

deadline=$(( SECONDS + WAIT_SHORT_SECS ))
reverted=no
while [ "${SECONDS}" -lt "${deadline}" ]; do
  current_cpu="$(kc get deployment app -n "${APP_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)"
  if [ "${current_cpu}" = "${declared_cpu}" ]; then
    reverted=yes
    break
  fi
  printf '  ... permintaan CPU saat ini: %s (menunggu kembali ke %s)\n' "${current_cpu:-?}" "${declared_cpu}"
  sleep 5
done
check_eq "selfHeal mengembalikan drift ke nilai git" "yes" "${reverted}"

log "Ringkasan"
kc get application project-management-app -n argocd
kc get pods -n "${APP_NAMESPACE}"
if [ "${FAILED}" -eq 0 ]; then
  echo "Seluruh pemeriksaan GitOps lolos."
else
  echo "${FAILED} pemeriksaan gagal."
  exit 1
fi
