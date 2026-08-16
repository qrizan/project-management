# Fungsi bersama untuk seluruh script reproduce. Di-source, bukan dieksekusi —
# karena itu tidak ber-shebang; shell targetnya dinyatakan lewat direktif di
# bawah supaya tetap bisa dianalisis static checker.
# shellcheck shell=bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# shellcheck source=versions.env
source "${REPO_ROOT}/scripts/reproduce/versions.env"

# Nama cluster dibaca dari manifest yang dipakai kind, bukan ditulis ulang di
# sini — supaya tidak ada dua sumber kebenaran yang bisa berbeda diam-diam.
# Nama namespace tetap konstanta script: namanya muncul di banyak manifest
# sekaligus, sehingga menurunkannya dari salah satu file justru lebih rapuh.
CLUSTER_NAME="$(awk '/^name:/ {print $2; exit}' "${REPO_ROOT}/k8s/kind-cluster.yaml")"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
readonly CLUSTER_NAME KUBE_CONTEXT

# Jaringan mesin ini terukur lambat dan beberapa image platform berukuran besar;
# satu pull pernah memakan 27 menit. Batas tunggu dibuat longgar supaya kegagalan
# yang dilaporkan benar-benar kegagalan, bukan sekadar kehabisan waktu tunggu.
# Ditulis dalam detik, lalu diturunkan ke bentuk yang dipakai `kubectl wait`,
# supaya tidak ada dua satuan waktu yang beredar bersamaan.
WAIT_SHORT_SECS=300
WAIT_LONG_SECS=1800
WAIT_SHORT="${WAIT_SHORT_SECS}s"
WAIT_LONG="${WAIT_LONG_SECS}s"
# WAIT_LONG dipakai oleh script yang men-source file ini, bukan di dalamnya.
# Penelusuran `source` hanya berjalan ke arah file yang dibaca, sehingga
# pemakaian di sisi pemanggil tidak terlihat oleh static checker.
# shellcheck disable=SC2034
readonly WAIT_SHORT_SECS WAIT_LONG_SECS WAIT_SHORT WAIT_LONG

log() {
  printf '\n=== %s\n' "$*"
}

fail() {
  printf '\nGAGAL: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "perintah '$1' tidak ada di PATH"
}

# kubectl selalu diarahkan ke context cluster ini supaya script tidak pernah
# mengenai cluster lain yang kebetulan sedang aktif.
kc() {
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

# Dua perlakuan Secret yang sengaja berbeda, dinamai supaya bedanya terbaca
# sebagai maksud, bukan sebagai gaya penulisan yang tidak konsisten.

# Dibuat sekali seumur cluster: nilainya di-generate acak dan menjadi sumber
# kebenaran. Menimpanya pada jalan berikutnya akan memutus akses ke data yang
# sudah terlanjur ditulis dengan kredensial lama.
create_secret_once() {
  local ns="$1" name="$2"
  shift 2
  if kc get secret "${name}" -n "${ns}" >/dev/null 2>&1; then
    log "Secret ${name} sudah ada, nilainya dipertahankan"
    return 0
  fi
  log "Membuat Secret ${name}"
  kc create secret generic "${name}" -n "${ns}" "$@"
}

# Selalu disamakan dengan sumbernya: isinya turunan dari Secret lain, jadi versi
# lama tidak boleh dipertahankan kalau sumbernya berubah.
apply_secret() {
  local ns="$1" name="$2"
  shift 2
  kc create secret generic "${name}" -n "${ns}" "$@" \
    --dry-run=client -o yaml | kc apply -f -
}

# Memasang atau memperbarui satu rilis Helm dari direktori chart di repo ini.
# Selalu `upgrade --install` supaya perintah yang sama berlaku untuk pemasangan
# pertama maupun pemasangan berikutnya.
#
# Penantian resource tetap dilakukan lewat `kubectl wait` di sisi pemanggil, bukan
# digantungkan ke --wait milik Helm: nilai bawaannya hanya menunggu hook, dan
# perilaku penantian custom resource pada pemasangan pertama lewat
# `upgrade --install` berbeda dari `install` biasa.
helm_release() {
  local name="$1" chart="$2"
  shift 2
  helm --kube-context "${KUBE_CONTEXT}" upgrade --install "${name}" \
    "${REPO_ROOT}/charts/${chart}" \
    --namespace "${APP_NAMESPACE}" \
    -f "${REPO_ROOT}/charts/${chart}/values-local.yaml" \
    --timeout "${WAIT_LONG}" \
    "$@"
}

# Mengambil satu nilai dari manifest hasil render chart. Dibaca dari hasil render,
# bukan dari values, supaya nilai yang dipakai script dijamin sama dengan yang
# benar-benar dikirim ke cluster — termasuk kalau nilainya ditimpa.
helm_rendered_value() {
  local chart="$1" key="$2"
  shift 2
  helm template render-only "${REPO_ROOT}/charts/${chart}" \
    --namespace "${APP_NAMESPACE}" \
    -f "${REPO_ROOT}/charts/${chart}/values-local.yaml" \
    "$@" \
    | awk -v key="${key}" '$1 == key { print $2; exit }'
}

# Alamat nyata di belakang Service `kubernetes`, beserta argumen yang menyalurkan
# alamat itu ke chart database.
#
# Dibaca dari cluster karena nilainya berbeda tiap lingkungan dan API server tidak
# punya Pod yang bisa diseleksi lewat label — satu-satunya cara menyebutnya di
# NetworkPolicy adalah blok alamat. Alamat Service sendiri tidak berlaku: aturan
# egress dievaluasi setelah alamat itu diterjemahkan ke alamat di belakangnya.
#
# Script yang memasang dan script yang memeriksa sama-sama memakai fungsi ini,
# supaya keduanya merender chart dengan nilai yang persis sama.
API_SERVER_ADDR=""
API_SERVER_PORT=""
DATABASE_VALUES_ARGS=()

read_api_server_endpoint() {
  API_SERVER_ADDR="$(kc get endpointslice kubernetes -n default \
    -o jsonpath='{.endpoints[0].addresses[0]}')"
  API_SERVER_PORT="$(kc get endpointslice kubernetes -n default \
    -o jsonpath='{.ports[0].port}')"
  [ -n "${API_SERVER_ADDR}" ] && [ -n "${API_SERVER_PORT}" ] \
    || fail "alamat API server tidak terbaca dari EndpointSlice 'kubernetes'"
  # Isinya dibaca oleh script yang men-source file ini, bukan di dalamnya —
  # pemakaian di sisi pemanggil tidak terlihat oleh static checker.
  # shellcheck disable=SC2034
  DATABASE_VALUES_ARGS=(
    --set "networkPolicy.egress.apiServer.cidr=${API_SERVER_ADDR}/32"
    --set "networkPolicy.egress.apiServer.port=${API_SERVER_PORT}"
  )
}

# `kubectl wait` pada Job yang gagal tetap menunggu sampai timeout habis, tanpa
# menunjukkan apa pun tentang sebabnya. Log Job ikut dicetak supaya kegagalan
# langsung bisa dibaca.
wait_job() {
  local ns="$1" job="$2" timeout="${3:-${WAIT_SHORT}}"
  if ! kc wait --for=condition=Complete "job/${job}" -n "${ns}" --timeout="${timeout}"; then
    echo "--- log Job ${job}:" >&2
    kc logs -n "${ns}" "job/${job}" --tail=100 >&2 || true
    fail "Job ${job} tidak selesai"
  fi
}

# `kubectl wait` tidak mengeluarkan apa pun selama menunggu, sehingga penantian
# belasan menit tidak bisa dibedakan dari proses yang menggantung. Loop ini
# mencetak phase Cluster tiap interval supaya progresnya terlihat dan bisa
# dipakai mendiagnosis kalau macet.
wait_cluster_ready() {
  local cluster="$1" timeout_secs="${2:-${WAIT_LONG_SECS}}"
  local deadline=$(( SECONDS + timeout_secs )) ready phase
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    ready="$(kc get cluster "${cluster}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "${ready}" = "True" ] && return 0
    phase="$(kc get cluster "${cluster}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    printf '  ... %s: %s\n' "${cluster}" "${phase:-menunggu status}"
    sleep 15
  done
  return 1
}

require_cluster() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
    || fail "cluster kind '${CLUSTER_NAME}' belum ada — jalankan 10-cluster.sh"
}

# Penghitung hasil untuk script pemeriksa. Seluruh pemeriksaan dijalankan sampai
# habis walau ada yang gagal, supaya satu kali jalan memberi gambaran penuh;
# jumlah kegagalan yang menentukan exit code di akhir.
FAILED=0

pass() { printf '  OK    %s\n' "$*"; }
bad()  { printf '  GAGAL %s\n' "$*"; FAILED=$((FAILED + 1)); }

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${label} (${actual})"
  else
    bad "${label} — diharapkan '${expected}', dapat '${actual}'"
  fi
}

# Menunggu alamat Gateway benar-benar melayani permintaan, bukan sekadar
# berstatus Programmed. Condition itu menyatakan konfigurasi sudah direkonsiliasi;
# proxy data-plane-nya sendiri masih dibangun beberapa saat sesudahnya, dan
# permintaan pada jendela itu ditolak dengan koneksi terputus. Bedanya baru
# terlihat pada Gateway yang baru dibuat ulang.
#
# Kode HTTP tidak diambil langsung dari keluaran curl: dengan -w, curl tetap
# mencetak 000 sebelum keluar dengan status gagal, sehingga menambahkan penanda
# lain di belakangnya menghasilkan nilai gabungan yang tidak berarti.
gateway_http_code() {
  local path="$1" timeout_secs="${2:-${WAIT_SHORT_SECS}}"
  local deadline=$(( SECONDS + timeout_secs ))
  local addr code=""
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    addr="$(kc get gateway project-management -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    if [ -n "${addr}" ]; then
      if code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 30 "http://${addr}${path}" 2>/dev/null)"; then
        if [ "${code}" = "200" ]; then
          echo "${code}"
          return 0
        fi
      else
        code=""
      fi
    fi
    printf '  ... Gateway %s: %s\n' "${addr:-tanpa alamat}" "${code:-belum menjawab}" >&2
    sleep 5
  done
  echo "${code:-gagal}"
}

# Menghitung baris satu tabel lewat instance primary sebuah Cluster CNPG.
# `kubectl exec` di sini dipakai untuk membaca isi database, bukan sebagai bukti
# konektivitas jaringan — jalurnya lewat API server, bukan jaringan antar Pod.
psql_count() {
  local cluster="$1" table="$2" primary
  primary="$(kc get cluster "${cluster}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.currentPrimary}')"
  kc exec -n "${APP_NAMESPACE}" "${primary}" -c postgres -- \
    psql -U postgres -d mydb -tAc "SELECT count(*) FROM \"${table}\""
}
