#!/usr/bin/env bash
# Mini benchmark para DNA (resto do matriz que não coube no bench principal).
set -euo pipefail
trap '' HUP

cd "$(dirname "$0")/../.."

LOG=bench-dna.log

pkill -f "WebServer 8000" 2>/dev/null || true
sleep 1
rm -f "$LOG"

java -javaagent:javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
     -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
     pt.ulisboa.tecnico.cnv.webserver.WebServer 8000 > "$LOG" 2>&1 &
WPID=$!
echo "Worker PID=$WPID"

# Wait for ready
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null --max-time 1 http://localhost:8000/ 2>/dev/null; then
        echo "Ready"; break
    fi
    sleep 1
done

REQS=(
    "dna_short_min1|/dna?seq1=seq1:ATGCATGCATGCATGC&seq2=seq2:GCATGCATGCAT&minLength=1&stopOnFirst=false"
    "dna_short_min3|/dna?seq1=seq1:ATGCATGCATGCATGC&seq2=seq2:GCATGCATGCAT&minLength=3&stopOnFirst=false"
    "dna_long_min3|/dna?seq1=seq1:ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGC&seq2=seq2:GCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT&minLength=3&stopOnFirst=false"
    "dna_long_min5_stopFirst|/dna?seq1=seq1:ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGC&seq2=seq2:GCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT&minLength=5&stopOnFirst=true"
)

for entry in "${REQS[@]}"; do
    label="${entry%%|*}"
    url="${entry#*|}"
    printf "  %-30s ... " "$label"
    HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:8000$url")
    echo "HTTP $HTTP"
done

sleep 1
kill "$WPID" 2>/dev/null || true
sleep 1
kill -9 "$WPID" 2>/dev/null || true

echo
echo "=== Metrics ==="
grep -E '^\[Metrics\]' "$LOG" || echo "(no metrics found)"
