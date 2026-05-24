#!/usr/bin/env bash
set -euo pipefail

cd /opt/delta_neutral

KEEP_DAYS="${KEEP_DAYS:-14}"
DRY_RUN="${DRY_RUN:-true}"

echo "[$(date -Is)] Pruning storage/backups older than ${KEEP_DAYS} days. DRY_RUN=${DRY_RUN}"

if [[ ! -d storage/backups ]]; then
  echo "storage/backups does not exist; nothing to do"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  find storage/backups -type f -mtime +"${KEEP_DAYS}" -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' | sort
else
  find storage/backups -type f -mtime +"${KEEP_DAYS}" -print -delete
  find storage/backups -type d -empty -print -delete
fi

echo "Done."
