# fleet-scale-grafana

Grafana dashboard for Fleet scale test results: `.jsonl` files with one JSON
object per line (`run started`, events, `metric` lines, a final `summary` with
`PASSED` / `FAILED` / `ERROR`). Runs locally in its own k3d cluster.

No Grafana install needed: Grafana and ClickHouse run as containers, set up
by the start script. Needs Linux with `docker`, `k3d`, `kubectl`, `jq`, `curl`,
`git`, internet on the first start (images, Grafana plugin), and free ports
3300 and 8123.

## Start

```bash
./grafana-k3d-up.sh <results folder | results repo git URL> [more ...]
```

Open <http://localhost:3300/d/fleet-scale-results> (no login; only reachable
from this machine, not from the network).

The sources are remembered: next time just run `./grafana-k3d-up.sh`.
New, changed and deleted result files show up within 15 s (git URLs: within 5 min).

## Stop

```bash
./grafana-k3d-down.sh
```

All data stays in `data/` (never committed) and is back on the next start.

## Push a file by hand

```bash
./push-results.sh <run folder or .jsonl file>
```

Results pushed this way stay on the dashboard, even if the file is deleted later.
