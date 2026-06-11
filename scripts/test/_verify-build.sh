#!/usr/bin/env bash
# Verifica que os fixes da sessão 2 estão presentes no JAR compilado.
set -uo pipefail
JAR="loadbalancer/target/loadbalancer-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
echo "=== Timestamps ==="
ls -la loadbalancer/src/main/java/pt/ulisboa/tecnico/cnv/loadbalancer/*.java "$JAR"

echo
echo "=== Métodos novos no AutoScaler.class ==="
TMP=$(mktemp -d)
unzip -q "$JAR" "pt/ulisboa/tecnico/cnv/loadbalancer/AutoScaler.class" -d "$TMP"
javap -p "$TMP/pt/ulisboa/tecnico/cnv/loadbalancer/AutoScaler.class" | grep -E "(handleUnhealthyEviction|discoverExistingWorkers)" || echo "(não encontrado)"

echo
echo "=== Métodos novos no WorkerPool.class ==="
unzip -q "$JAR" "pt/ulisboa/tecnico/cnv/loadbalancer/WorkerPool.class" -d "$TMP"
javap -p "$TMP/pt/ulisboa/tecnico/cnv/loadbalancer/WorkerPool.class" | grep -E "(setOnUnhealthyEviction|onUnhealthyEviction)" || echo "(não encontrado)"

rm -rf "$TMP"
