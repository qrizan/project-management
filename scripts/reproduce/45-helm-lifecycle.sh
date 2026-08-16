#!/usr/bin/env bash
# Memeriksa Definition of Done Fase 3 sebagai pemeriksaan yang bisa gagal.
#
# Dijalankan setelah 40-app.sh terhadap rilis yang sudah hidup, karena sebagian
# pemeriksaannya memang menguji perpindahan keadaan — pembaruan nilai dan
# pencabutan rilis — bukan bentuk manifestnya saja.
#
# Script ini mengubah keadaan rilis lalu mengembalikannya. Kalau berhenti di
# tengah, rilis aplikasi bisa tertinggal dengan nilai uji atau bahkan tercabut;
# menjalankan ulang 40-app.sh mengembalikannya.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need kubectl
need helm
need curl
require_cluster

APP_RELEASE=app

# Nilai pembanding untuk uji pembaruan. Sengaja berbeda dari nilai chart mana pun
# supaya kemunculannya di objek yang hidup hanya bisa berasal dari upgrade ini.
CPU_PROBE=150m

app_cpu_request() {
  kc get deployment "${APP_RELEASE}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
}

# Chart database menuntut alamat API server diisi; nilainya dibaca dari cluster
# supaya lint dan validasi di sini memakai masukan yang sama dengan pemasangan.
read_api_server_endpoint

log "1. helm lint"
for chart in database app; do
  extra=()
  if [ "${chart}" = database ]; then extra=("${DATABASE_VALUES_ARGS[@]}"); fi
  if helm lint "${REPO_ROOT}/charts/${chart}" \
       -f "${REPO_ROOT}/charts/${chart}/values-local.yaml" "${extra[@]}" >/dev/null; then
    pass "chart ${chart}"
  else
    bad "chart ${chart} tidak lolos lint"
  fi
done

# Render diuji terhadap API server, bukan sekadar diperiksa sintaksnya. Custom
# resource seperti Cluster, ObjectStore, dan HTTPRoute hanya bisa divalidasi
# terhadap cluster yang punya definisinya.
log "2. Manifest hasil render diterima API server"
for chart in database app; do
  extra=()
  if [ "${chart}" = database ]; then extra=("${DATABASE_VALUES_ARGS[@]}"); fi
  if helm template "${chart}" "${REPO_ROOT}/charts/${chart}" \
       --namespace "${APP_NAMESPACE}" \
       -f "${REPO_ROOT}/charts/${chart}/values-local.yaml" "${extra[@]}" \
       | kc apply --dry-run=server -f - >/dev/null; then
    pass "chart ${chart}"
  else
    bad "chart ${chart} ditolak saat validasi server"
  fi
done

# Kalau kedua objek sama-sama menyebut jumlah replica, penerapan ulang manifest
# akan membatalkan hasil penskalaan. Yang diperiksa: hanya satu yang menyebutnya,
# dan pilihannya ditentukan oleh satu saklar.
log "3. replicas dan HPA tidak pernah muncul bersamaan"
for state in true false; do
  rendered="$(helm template "${APP_RELEASE}" "${REPO_ROOT}/charts/app" \
    --namespace "${APP_NAMESPACE}" \
    -f "${REPO_ROOT}/charts/app/values-local.yaml" \
    --set autoscaling.enabled="${state}")"
  # Ditulis sebagai `if`, bukan `cmd && var=yes`: grep yang tidak menemukan apa
  # pun mengembalikan status gagal, dan bentuk kedua akan menghentikan script.
  has_replicas=no
  has_hpa=no
  if grep -qE '^  replicas:' <<<"${rendered}"; then has_replicas=yes; fi
  if grep -qE '^kind: HorizontalPodAutoscaler' <<<"${rendered}"; then has_hpa=yes; fi
  if [ "${state}" = true ]; then
    check_eq "autoscaling aktif — replicas dirender" "no" "${has_replicas}"
    check_eq "autoscaling aktif — HPA dirender" "yes" "${has_hpa}"
  else
    check_eq "autoscaling mati — replicas dirender" "yes" "${has_replicas}"
    check_eq "autoscaling mati — HPA dirender" "no" "${has_hpa}"
  fi
done

log "4. helm upgrade mengubah objek yang sudah berjalan"
# Acuan diambil dari objek yang hidup sekarang, bukan dari nilai di chart:
# yang diuji adalah nilai kembali ke keadaan semula, apa pun keadaan itu.
CPU_DEFAULT="$(app_cpu_request)"
if helm_release "${APP_RELEASE}" app --set resources.requests.cpu="${CPU_PROBE}" >/dev/null; then
  kc rollout status "deployment/${APP_RELEASE}" -n "${APP_NAMESPACE}" --timeout="${WAIT_SHORT}" >/dev/null \
    || bad "rollout setelah upgrade tidak selesai"
  check_eq "permintaan CPU setelah upgrade" "${CPU_PROBE}" "$(app_cpu_request)"
else
  bad "helm upgrade gagal"
fi

if helm_release "${APP_RELEASE}" app >/dev/null; then
  kc rollout status "deployment/${APP_RELEASE}" -n "${APP_NAMESPACE}" --timeout="${WAIT_SHORT}" >/dev/null \
    || bad "rollout setelah pengembalian nilai tidak selesai"
  check_eq "permintaan CPU setelah dikembalikan" "${CPU_DEFAULT}" "$(app_cpu_request)"
else
  bad "helm upgrade pengembalian nilai gagal"
fi

# Inti dari pemisahan dua rilis: rilis aplikasi dicabut dan dipasang lagi tanpa
# database ikut hilang. Acuan jumlah baris diambil sebelum pencabutan, lalu
# dipakai apa adanya — membaca ulang setelahnya membuat pembanding ikut bergerak.
log "5. Mencabut rilis aplikasi tidak menyentuh database"
declare -A EXPECTED
for table in Project Category User; do
  EXPECTED["${table}"]="$(psql_count postgres "${table}")"
done
printf '  acuan: Project=%s Category=%s User=%s\n' \
  "${EXPECTED[Project]}" "${EXPECTED[Category]}" "${EXPECTED[User]}"

helm --kube-context "${KUBE_CONTEXT}" uninstall "${APP_RELEASE}" -n "${APP_NAMESPACE}" >/dev/null

if kc get deployment "${APP_RELEASE}" -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
  bad "Deployment aplikasi masih ada setelah rilis dicabut"
else
  pass "Deployment aplikasi terhapus"
fi

if kc get cluster postgres -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
  pass "Cluster postgres bertahan"
else
  bad "Cluster postgres ikut terhapus — pemisahan rilis tidak berlaku"
fi

pvc_count="$(kc get pvc -n "${APP_NAMESPACE}" -l cnpg.io/cluster=postgres --no-headers 2>/dev/null | wc -l)"
if [ "${pvc_count}" -gt 0 ]; then
  pass "PersistentVolumeClaim database bertahan (${pvc_count})"
else
  bad "PersistentVolumeClaim database ikut terhapus"
fi

log "Memasang ulang rilis aplikasi"
helm_release "${APP_RELEASE}" app >/dev/null
kc rollout status "deployment/${APP_RELEASE}" -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}" >/dev/null \
  || bad "rollout setelah pemasangan ulang tidak selesai"
# Gateway yang dipasang ulang mendapat alamat baru dari penyedia LoadBalancer,
# jadi alamatnya dibaca lagi setelah Programmed — bukan yang lama.
kc wait --for=condition=Programmed gateway/project-management \
  -n "${APP_NAMESPACE}" --timeout="${WAIT_LONG}" >/dev/null \
  || bad "Gateway tidak Programmed setelah pemasangan ulang"

for table in Project Category User; do
  check_eq "jumlah ${table} setelah dipasang ulang" \
    "${EXPECTED[${table}]}" "$(psql_count postgres "${table}")"
done
check_eq "HTTP lewat Gateway setelah dipasang ulang" "200" \
  "$(gateway_http_code /auth/signin "${WAIT_LONG_SECS}")"

log "Ringkasan"
if [ "${FAILED}" -eq 0 ]; then
  echo "Seluruh pemeriksaan siklus hidup Helm lolos."
else
  echo "${FAILED} pemeriksaan gagal."
  echo "Rilis aplikasi mungkin tertinggal dalam keadaan uji — jalankan 40-app.sh untuk mengembalikannya."
  exit 1
fi
