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
