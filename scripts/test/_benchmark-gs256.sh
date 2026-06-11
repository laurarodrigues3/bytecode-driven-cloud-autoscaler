#!/usr/bin/env bash
# Mini benchmark: GrayScott size=256 (não coube no run principal por timeout).
set -euo pipefail
trap '' HUP

cd "$(dirname "$0")/../.."

LOG=bench-gs256.log

pkill -f "WebServer 8000" 2>/dev/null || true
sleep 1
rm -f "$LOG"

java -javaagent:javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
     -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
     pt.ulisboa.tecnico.cnv.webserver.WebServer 8000 > "$LOG" 2>&1 &
WPID=$!
echo "Worker PID=$WPID"

for i in 1 2 3 4 5; do
    if curl -s -o /dev/null --max-time 1 http://localhost:8000/ 2>/dev/null; then echo "Ready"; break; fi
    sleep 1
done

# Apenas s256 com maxIter=1000 (metade do que estava no plano original, para
# manter total <10s incluindo JIT warmup).
REQS=(
    "gs_s256_run_center|/grayscott?size=256&maxIterations=1000&stopOnExtinction=false&seedMode=center"
    "gs_s256_stop_center|/grayscott?size=256&maxIterations=1000&stopOnExtinction=true&seedMode=center"
)

for entry in "${REQS[@]}"; do
    label="${entry%%|*}"
    url="${entry#*|}"
    printf "  %-30s ... " "$label"
    HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "http://localhost:8000$url")
    echo "HTTP $HTTP"
done

sleep 1
kill "$WPID" 2>/dev/null || true
sleep 1
kill -9 "$WPID" 2>/dev/null || true

echo
echo "=== Metrics ==="
grep -E '^\[Metrics\]' "$LOG" || echo "(no metrics found)"
