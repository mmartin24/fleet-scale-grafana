#!/bin/bash
# Keeps ClickHouse in sync with the .jsonl files in the results folders.
# Usage: watch-results.sh <results folder | git URL> [more ...]
#
# A git URL (a published results repo) is cloned to data/published/<name>
# and pulled every ~5 min; its rows are marked published.
#
# The watched files (plus results pushed by hand) are the truth, the table
# is a copy of them:
# - on start, and whenever a file was deleted or rewritten (not just
#   appended to), the whole table is rebuilt from the files: pushed into a
#   side table, then swapped in at once, so the dashboard never sees a
#   half-filled table;
# - a new or growing file is pushed whole; lines already in the table are
#   dropped as duplicates (see clickhouse/init.sql);
# - results pushed by hand with push-results.sh are never removed: every
#   rebuild copies them back in from table fleet_scale_manual.
# Polls every 15s; a failed push or rebuild is retried next cycle.
# Started by grafana-k3d-up.sh, stopped by grafana-k3d-down.sh.
set -uo pipefail
cd "$(dirname "$0")"

[[ $# -ge 1 ]] || { echo "usage: $0 <results folder | git URL> [more ...]" >&2; exit 1; }

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
TABLE=fleet_scale_results

declare -A repos    # clone folder -> URL
dirs=()
for arg in "$@"; do
  if [[ $arg == *://* || $arg == git@* ]]; then
    d=data/published/$(basename "$arg" .git)
    repos[$d]=$arg
    dirs+=("$d")
  else
    dirs+=("$arg")
  fi
done

log() { echo "$(date -u +%FT%TZ) $*"; }
ch() { curl -fsS "$CLICKHOUSE_URL/" --data-binary "$1"; }
sha() { sha256sum | cut -d' ' -f1; }

sync_repos() {
  local d
  for d in "${!repos[@]}"; do
    if [[ -d $d/.git ]]; then
      git -C "$d" pull -q --ff-only || log "pull failed, will retry: ${repos[$d]}"
    else
      git clone -q "${repos[$d]}" "$d" || log "clone failed, will retry: ${repos[$d]}"
    fi
  done
}

list_files() {
  local dir
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] && find "$dir" -name '*.jsonl' -print0
  done | sort -z
}

declare -A pushed_sha pushed_size   # file -> sha256 / size of the content last pushed

rebuild() {
  local files=() f
  declare -A new_sha new_size
  mapfile -d '' files < <(list_files)
  # Fingerprint before pushing: if a file grows meanwhile, the next scan
  # sees the change and pushes it again.
  for f in "${files[@]}"; do new_sha[$f]=$(sha < "$f"); new_size[$f]=$(stat -c %s "$f"); done
  # Results pushed by hand (fleet_scale_manual, see push-results.sh) are
  # always carried over, whether or not their file still exists.
  ch "DROP TABLE IF EXISTS ${TABLE}_new" && ch "CREATE TABLE ${TABLE}_new AS $TABLE" \
    && ch "CREATE TABLE IF NOT EXISTS fleet_scale_manual AS $TABLE" \
    && ch "INSERT INTO ${TABLE}_new SELECT * FROM fleet_scale_manual" || return 1
  if [[ ${#files[@]} -gt 0 ]]; then
    WATCHER=1 TABLE=${TABLE}_new ./push-results.sh "${files[@]}" > /dev/null || return 1
  fi
  ch "EXCHANGE TABLES $TABLE AND ${TABLE}_new" && ch "DROP TABLE ${TABLE}_new" || return 1
  pushed_sha=(); pushed_size=()
  for f in "${files[@]}"; do pushed_sha[$f]=${new_sha[$f]}; pushed_size[$f]=${new_size[$f]}; done
  log "rebuilt from ${#files[@]} files"
}

# Returns 1 if the table must be rebuilt (a file was deleted or rewritten).
scan() {
  local files=() f s n
  declare -A seen
  mapfile -d '' files < <(list_files)
  for f in "${files[@]}"; do
    seen[$f]=1
    s=$(sha < "$f"); n=$(stat -c %s "$f")
    [[ ${pushed_sha[$f]:-} == "$s" ]] && continue
    if [[ -n ${pushed_sha[$f]:-} && $(head -c "${pushed_size[$f]}" "$f" | sha) != "${pushed_sha[$f]}" ]]; then
      log "rewritten: $f"
      return 1
    fi
    if WATCHER=1 ./push-results.sh "$f" > /dev/null 2>&1; then
      pushed_sha[$f]=$s; pushed_size[$f]=$n
      log "pushed: $f"
    else
      log "push failed, will retry: $f"
    fi
  done
  for f in "${!pushed_sha[@]}"; do
    [[ -n ${seen[$f]:-} ]] || { log "deleted: $f"; return 1; }
  done
}

echo "watching: $*"
in_sync=0
for ((i = 0; ; i++)); do
  (( i % 20 == 0 )) && sync_repos
  if (( in_sync )); then
    scan || in_sync=0
  fi
  if (( ! in_sync )); then
    rebuild && in_sync=1 || log "rebuild failed, will retry"
  fi
  sleep 15
done
