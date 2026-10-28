#!/bin/bash
# Spin up a dedicated k3d cluster running Grafana + ClickHouse for the
# Fleet scale results dashboard. Safe to run repeatedly: creates the cluster only
# if missing, and (re)applies manifests/configmaps either way.
set -euo pipefail

# Results sources (folders and published repo git URLs) given as arguments
# are remembered in data/sources, so after the first run a plain
# ./grafana-k3d-up.sh restarts the watcher on the same sources.
sources=()
for arg in "$@"; do
	if [[ $arg == *://* || $arg == git@* ]]; then sources+=("$arg"); else sources+=("$(realpath -m "$arg")"); fi
done

cd "$(dirname "$0")"
mkdir -p data
if [[ ${#sources[@]} -gt 0 ]]; then
	printf '%s\n' "${sources[@]}" > data/sources
elif [[ -f data/sources ]]; then
	mapfile -t sources < data/sources
fi

CLUSTER_NAME="fleet-results"
DATA_DIR="$(pwd)/data/clickhouse"
GRAFANA_DATA_DIR="$(pwd)/data/grafana"

mkdir -p "$DATA_DIR"
# Grafana's container runs as uid 472; the host dir is created as us, so
# open it up rather than fight uid mismatches for a local dev spike.
mkdir -p "$GRAFANA_DATA_DIR" && chmod 777 "$GRAFANA_DATA_DIR"

# Ports listen on this machine only: Grafana logs everyone in as admin and
# ClickHouse has no password, so they must not be reachable from the network.
if ! k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
	echo "Creating k3d cluster ${CLUSTER_NAME}..."
	k3d cluster create "$CLUSTER_NAME" \
		--volume "${DATA_DIR}:/data/clickhouse@server:0" \
		--volume "${GRAFANA_DATA_DIR}:/data/grafana@server:0" \
		-p "127.0.0.1:3300:30300@server:0" \
		-p "127.0.0.1:8123:30081@server:0" \
		--wait
else
	echo "k3d cluster ${CLUSTER_NAME} already exists, reusing it."
fi
# Standalone kubeconfig file, unaffected by any ambient $KUBECONFIG.
export KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")"
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

kubectl apply -f manifests/namespace.yaml

kubectl create configmap clickhouse-init \
	--from-file=init.sql=clickhouse/init.sql \
	-n fleet-results --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-datasources \
	--from-file=grafana/provisioning/datasources/ \
	-n fleet-results --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboards-provisioning \
	--from-file=grafana/provisioning/dashboards/ \
	-n fleet-results --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboards \
	--from-file=grafana/dashboards/ \
	-n fleet-results --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f manifests/clickhouse.yaml -f manifests/grafana.yaml

kubectl -n fleet-results rollout status deployment/clickhouse --timeout=120s
kubectl -n fleet-results rollout status deployment/grafana --timeout=120s

# Grafana installs the ClickHouse plugin at container startup; give it a
# moment before the pod is actually usable even though it reports Ready.
sleep 5

echo
echo "Grafana:    http://localhost:3300/d/fleet-scale-results"
echo
echo "Push data with: ./push-results.sh <run folder or .jsonl files>"
echo "Tear down with: ./grafana-k3d-down.sh (data in ${DATA_DIR} is preserved)"

# Watch the results sources and push new results automatically. Always
# restarted, so new sources take effect; the re-push on start is harmless.
if [[ ${#sources[@]} -gt 0 ]]; then
	if [[ -f data/watcher.pid ]]; then kill "$(cat data/watcher.pid)" 2>/dev/null || true; fi
	nohup ./watch-results.sh "${sources[@]}" >> data/watcher.log 2>&1 &
	echo $! > data/watcher.pid
	echo "Watcher running (pid $!, log: data/watcher.log), watching:"
	printf '  %s\n' "${sources[@]}"
else
	echo "No results sources yet. Run once with them, they are remembered:"
	echo "  ./grafana-k3d-up.sh <results folder | published repo git URL> [more ...]"
fi
