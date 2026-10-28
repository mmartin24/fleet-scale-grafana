#!/bin/bash
# Pushes test .jsonl results into ClickHouse for the Grafana dashboard
# (start the dashboard stack with ./grafana-k3d-up.sh first).
#
# Usage:
#   ./push-results.sh <run folder or .jsonl file> [more of the same ...]
#
# Converts EVERY jsonl line into one ClickHouse row:
#   {"event":"metric",...}   -> metric, value, unit as written
#   {"event":"summary",...}  -> metric=run, value=run duration (s), with
#                               status/expected/actual/image/bundles in labels
#   any other text event     -> metric=event, value=seconds since run start,
#                               text in labels.event
# Every row carries env, scenario, fleet_version, clusters (copied from the
# "run started" line when the line itself has no such fields). env falls back
# to the aws/local folder in the file path. Files under data/published/ (git
# clones made by watch-results.sh) are marked published.
#
# Old files have no metric lines; their numbers only exist in text events
# ("cycle 1: orphaned_secrets=0 etcd_size=581M", ...). For those files the
# same metrics are parsed from the text, so old and new runs plot together.
#
# Pushing a file twice is harmless: the table drops identical rows
# (clickhouse/init.sql).
#
# Run by hand, the rows are also stored in table fleet_scale_manual, which
# nothing ever rebuilds or deletes: watch-results.sh copies it into every
# rebuild, so hand-pushed results stay, even if their file is gone later.
# (watch-results.sh sets WATCHER=1 to skip that copy for watched files.)
set -euo pipefail

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
TABLE="${TABLE:-fleet_scale_results}"

[[ $# -ge 1 ]] || { echo "usage: $0 <run folder or .jsonl file> [more ...]" >&2; exit 1; }

# Collect files (expand folders to their .jsonl).
files=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    mapfile -d '' found < <(find "$arg" -name '*.jsonl' -print0 | sort -z)
    [[ ${#found[@]} -gt 0 ]] || { echo "no .jsonl files in $arg" >&2; exit 1; }
    files+=("${found[@]}")
  else
    [[ -f "$arg" ]] || { echo "not a file or folder: $arg" >&2; exit 1; }
    files+=("$arg")
  fi
done

# One file at a time (slurped), so each line can see its run's "run started"
# line and whether the file has metric lines at all.
convert() {
  jq -c -s --arg path "$1" '
    # Metrics old test versions only wrote as text; names match the metric
    # lines new versions write.
    def legacy_metrics:
      (capture("created-to-ready: (?<v>[0-9]+)s")
        | {metric: "gitrepo_created_to_ready_seconds", value: (.v|tonumber), unit: "s"}),
      (capture("orphaned_secrets=(?<o>[0-9]+) etcd_size=(?<s>[0-9.]+)(?<u>[MG])")
        | {metric: "orphaned_secrets", value: (.o|tonumber), unit: "count"},
          {metric: "etcd_size_bytes", value: ((.s|tonumber) * (if .u == "G" then 1073741824 else 1048576 end) | floor), unit: "bytes"}),
      (capture("controller resync time: (?<v>[0-9]+)s")
        | {metric: "controller_resync_seconds", value: (.v|tonumber), unit: "s"}),
      (capture("final bundledeployment count: (?<v>[0-9]+)")
        | {metric: "bundledeployments_final", value: (.v|tonumber), unit: "count"}),
      (capture("(?<p>phase[0-9]-[a-z]+) wave [0-9]+: status.commit=[0-9a-f]+ observed after (?<v>[0-9]+)s")
        | {metric: "update_latency_\(.p)_seconds", value: (.v|tonumber), unit: "s"}),
      (capture("stale bundledeployments from superseded commits: (?<v>[0-9]+)")
        | {metric: "stale_bundledeployments", value: (.v|tonumber), unit: "count"}),
      (capture("still pointing at deleted commit [0-9a-f]+: (?<v>[0-9]+)")
        | {metric: "bundledeployments_on_deleted_commit", value: (.v|tonumber), unit: "count"}),
      (capture("leftover bundles=(?<b>[0-9]+) leftover bundledeployments=(?<d>[0-9]+)")
        | {metric: "leftover_bundles", value: (.b|tonumber), unit: "count"},
          {metric: "leftover_bundledeployments", value: (.d|tonumber), unit: "count"});

    def str: if . == null then "" else tostring end;

    any(.[]; .event == "metric") as $has_metrics
    | (($path | capture("(^|/)(?<e>aws|local)/").e) // "unknown") as $path_env
    | (if ($path | test("(^|/)data/published/")) then 1 else 0 end) as $published
    | foreach .[] as $l ({}; if $l.event == "run started" then $l else . end;
        . as $r
        | {ts: $l.ts, run_label: ($l.run_id // $r.run_id // "" | str), published: $published,
           labels: {env: ($l.env // $r.env // $path_env | str),
                    scenario: ($l.scenario // $r.scenario | str),
                    fleet_version: ($l.fleet_version // $r.fleet_version | str),
                    clusters: ($r.clusters_registered // $l.clusters_registered | str)}} as $row
        | (($l.ts | fromdate) - (($r.ts // $l.ts) | fromdate)) as $since_start
        | if $l.event == "metric" then
            $row + {metric: $l.metric, value: $l.value, unit: ($l.unit | str)}
          elif $l.event == "summary" then
            $row + {metric: "run", value: $since_start, unit: "s"}
            | .labels += {status: ($l.status // "ERROR"), expected: ($l.expected | str), actual: ($l.actual | str),
                          image: ($l.fleet_controller_image // $r.fleet_controller_image | str),
                          bundles: ($l.bundles // $r.bundles | str)}
          else
            ($row + {metric: "event", value: $since_start, unit: "s"} | .labels.event = ($l.event | str)),
            (if $has_metrics then empty else $row + ($l.event | str | legacy_metrics) end)
          end)' "$1"
}

# --data-binary @- keeps the insert out of the URL; the query itself goes in
# the URL because ClickHouse treats a POST body not starting with INSERT as
# data. date_time_input_format=best_effort makes ClickHouse accept the
# tests' RFC3339 "Z" timestamps, which its default parser rejects.
rows="$(for f in "${files[@]}"; do convert "$f"; done)"
[[ -n "$rows" ]] || { echo "nothing to push" >&2; exit 1; }

insert() {
  printf '%s\n' "$rows" | curl -fsS \
    "$CLICKHOUSE_URL/?date_time_input_format=best_effort&query=INSERT%20INTO%20$1%20FORMAT%20JSONEachRow" \
    --data-binary @-
}
if [[ -z "${WATCHER:-}" ]]; then
  # Keep copy first: if the second insert fails, a retry is still harmless.
  curl -fsS "$CLICKHOUSE_URL/" --data-binary "CREATE TABLE IF NOT EXISTS fleet_scale_manual AS fleet_scale_results"
  insert fleet_scale_manual
fi
insert "$TABLE"
echo "Pushed $(printf '%s\n' "$rows" | wc -l) rows into ClickHouse (table ${TABLE}). Open Grafana at http://localhost:3300."
