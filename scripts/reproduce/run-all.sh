#!/usr/bin/env bash
# Membangun ulang seluruh orkestrasi Fase 2 dari nol lalu memeriksanya.
#
#   scripts/reproduce/run-all.sh          bangun di atas keadaan yang ada
#   scripts/reproduce/run-all.sh --clean  hapus dulu, lalu bangun dari nol
#
# Tiap tahap juga bisa dijalankan sendiri, urutannya mengikuti awalan angka.
# Menjalankan penuh memakan waktu lama, sebagian besar habis untuk menarik
# image platform dan membangun image aplikasi.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE="$(dirname "${BASH_SOURCE[0]}")"

if [ "${1:-}" = "--clean" ]; then
  "${HERE}/00-teardown.sh"
fi

"${HERE}/10-cluster.sh"
"${HERE}/20-platform.sh"
"${HERE}/30-storage.sh"
"${HERE}/40-app.sh"
"${HERE}/45-helm-lifecycle.sh"
"${HERE}/47-observability.sh"
"${HERE}/48-alert-drill.sh"
"${HERE}/50-verify.sh"
"${HERE}/60-restore-drill.sh"
