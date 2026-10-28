#!/bin/bash
# Tear down the k3d cluster. ClickHouse's data directory lives on the host
# (see grafana-k3d-up.sh's --volume mount), not inside the cluster, so it survives this.
set -euo pipefail

cd "$(dirname "$0")"

CLUSTER_NAME="fleet-results"
DATA_DIR="$(pwd)/data/clickhouse"

# Stop the results watcher if up.sh started one.
if [[ -f data/watcher.pid ]]; then
	kill "$(cat data/watcher.pid)" 2>/dev/null || true
	rm -f data/watcher.pid
fi

k3d cluster delete "$CLUSTER_NAME"

echo "Cluster deleted. Results data preserved on disk at ${DATA_DIR}."
echo "Run ./grafana-k3d-up.sh again to bring it back with the same data."
