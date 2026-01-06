#!/usr/bin/env bash
set -euo pipefail

# ========== CONNECTION CONFIG ==========
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
MYSQL_IMAGE="mysql:8.4"

OUT_DIR="./ovh-db-backups"
MAX_JOBS=20   # <-- parallelism
# =======================================

SCHEMAS=(
  danny-bacon-db
  flowdoro-calendar
  servershards-dev-build
  servershards-development
  servershards-local
  servershards-production
  smartcab
  vp-db-development
  vp-db-production
  workplanner
  JNE-HOME
)

mkdir -p "$OUT_DIR"
TS="$(date +'%Y-%m-%d_%H-%M-%S')"
RUN_DIR="$OUT_DIR/$TS"
mkdir -p "$RUN_DIR"

echo "Dumping ${#SCHEMAS[@]} schemas -> $RUN_DIR"
echo "Parallel jobs: $MAX_JOBS"

FAIL=0

dump_one() {
  local S="$1"

  local SAFE_NAME="${S//[^a-zA-Z0-9_.-]/_}"

  # Container name "is" the schema, with a tiny suffix to guarantee uniqueness in parallel
  local CONTAINER_NAME="$SAFE_NAME-$$-$RANDOM"

  local OUT_FILE="$RUN_DIR/${S}.sql"
  local LOG_FILE="$RUN_DIR/${S}.log"

  echo "==> Dumping schema: $S  (container: $CONTAINER_NAME)"

  if ! docker run --rm --name "$CONTAINER_NAME" -i \
      -e MYSQL_PWD="$DB_PASS" \
      "$MYSQL_IMAGE" \
      mysqldump \
        --quote-names \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USER" \
        --ssl-mode=REQUIRED \
        --no-tablespaces \
        --single-transaction \
        --quick \
        --databases "$S" \
      > "$OUT_FILE" 2> "$LOG_FILE"; then
    echo "!! FAILED: $S (see $LOG_FILE)" >&2
    return 1
  fi

  echo "    Saved: $OUT_FILE"
}

wait_for_slot() {
  while (( $(jobs -pr | wc -l) >= MAX_JOBS )); do
    sleep 0.2
  done
}

for S in "${SCHEMAS[@]}"; do
  wait_for_slot
  dump_one "$S" &
done

for pid in $(jobs -pr); do
  if ! wait "$pid"; then
    FAIL=1
  fi
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "One or more dumps failed. Check *.log files in: $RUN_DIR" >&2
  exit 1
fi

echo "All schema dumps completed successfully."
