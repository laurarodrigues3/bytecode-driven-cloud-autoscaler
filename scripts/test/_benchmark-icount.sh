#!/usr/bin/env bash
# Benchmark de calibração ICount.
#
# Arranca um worker local instrumentado (sem AWS), envia uma matriz curada
# de pedidos sequencialmente, parses os [Metrics] do log e produz um CSV.
#
# Usa-se para:
#   1) calibrar AutoScaler.ESTIMATED_WORK_THRESHOLD e WorkerPool.DEFAULT_MAX_CAPACITY
#      com a magnitude real do instructionCount observado.
#   2) validar/refinar features no ComplexityEstimator (especialmente GrayScott
#      onde stopOnExtinction/seedMode podem cortar trabalho).
#
# Output:
#   - bench-worker.log        (stdout do worker, com linhas [Metrics] e [JavassistAgent])
#   - bench-icount.csv        (uma linha por pedido, parseado para análise)
#   - bench-metrics-lines.txt (intermédio: só as linhas [Metrics] do log)

set -euo pipefail

# Ignorar SIGHUP para sobreviver à morte da shell-pai (acontece quando o
# comando é invocado em modo async pelo IDE/Cascade).
trap '' HUP

cd "$(dirname "$0")/../.."

PORT=8000
LOG=bench-worker.log
CSV=bench-icount.csv
METRICS_RAW=bench-metrics-lines.txt

JAR_AGENT="javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
JAR_WS="webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

# ─── Validar pré-requisitos ────────────────────────────────────────────────
if [ ! -f "$JAR_AGENT" ] || [ ! -f "$JAR_WS" ]; then
    echo "[ERRO] JARs não encontrados. Correr primeiro:"
    echo "       mvn -q package -DskipTests"
    exit 1
fi

# ─── Cleanup garantido ─────────────────────────────────────────────────────
WORKER_PID=""
cleanup() {
    if [ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null; then
        echo
        echo "[cleanup] A parar worker PID $WORKER_PID..."
        kill "$WORKER_PID" 2>/dev/null || true
        # Esperar até 5s para flush dos buffers de stdout
        for i in 1 2 3 4 5; do
            kill -0 "$WORKER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$WORKER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ─── Cleanup defensivo de runs anteriores (worker órfão na mesma porta) ──
echo "[bench] A limpar possíveis workers órfãos na porta $PORT..."
pkill -f "WebServer $PORT" 2>/dev/null || true
sleep 1

# ─── Arrancar worker ───────────────────────────────────────────────────────
echo "[bench] A arrancar worker na porta $PORT..."
rm -f "$LOG" "$METRICS_RAW" "$CSV"
java -javaagent:"$JAR_AGENT" -cp "$JAR_WS" \
     pt.ulisboa.tecnico.cnv.webserver.WebServer "$PORT" \
     >"$LOG" 2>&1 &
WORKER_PID=$!
echo "[bench] Worker PID=$WORKER_PID, log=$LOG"

# Wait for readiness
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/" 2>/dev/null; then
        echo "[bench] Worker pronto."
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "[ERRO] Worker não arrancou em 15s. Tail do log:"
        tail -50 "$LOG"
        exit 1
    fi
    sleep 1
done
echo

# ─── Matriz de pedidos ─────────────────────────────────────────────────────
# Formato: "label|url"
# Lista pensada para cobrir:
#   - 5 magnitudes de fractals (xs → xl)
#   - 8 combinações de grayscott para isolar effect de size, stopOnExtinction, seedMode
#   - 4 variações de dna (minLength + comprimento de sequências)
REQUESTS=(
    # ── Fractals: 4 magnitudes (suficiente para fittar linha y=k*x) ──
    # NB: com agent overhead ~3-5x, pedidos >1e9 trabalho unitário ficam impraticáveis.
    "fractals_xs|/fractals?w=200&h=200&iterations=50"
    "fractals_s|/fractals?w=400&h=400&iterations=100"
    "fractals_m|/fractals?w=600&h=600&iterations=200"
    "fractals_l|/fractals?w=1000&h=1000&iterations=500"

    # ── GrayScott: isolar size, stopOnExtinction, seedMode ──
    "grayscott_s64_run_center|/grayscott?size=64&maxIterations=1000&stopOnExtinction=false&seedMode=center"
    "grayscott_s64_stop_center|/grayscott?size=64&maxIterations=1000&stopOnExtinction=true&seedMode=center"
    "grayscott_s128_run_center|/grayscott?size=128&maxIterations=2000&stopOnExtinction=false&seedMode=center"
    "grayscott_s128_stop_center|/grayscott?size=128&maxIterations=2000&stopOnExtinction=true&seedMode=center"
    "grayscott_s128_run_corners|/grayscott?size=128&maxIterations=2000&stopOnExtinction=false&seedMode=corners"
    "grayscott_s256_run_center|/grayscott?size=256&maxIterations=2000&stopOnExtinction=false&seedMode=center"
    "grayscott_s256_stop_center|/grayscott?size=256&maxIterations=2000&stopOnExtinction=true&seedMode=center"

    # ── DNA: efeito do minLength e comprimento das sequências ──
    "dna_short_min1|/dna?seq1=seq1:ATGCATGCATGCATGC&seq2=seq2:GCATGCATGCAT&minLength=1&stopOnFirst=false"
    "dna_short_min3|/dna?seq1=seq1:ATGCATGCATGCATGC&seq2=seq2:GCATGCATGCAT&minLength=3&stopOnFirst=false"
    "dna_long_min3|/dna?seq1=seq1:ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGC&seq2=seq2:GCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT&minLength=3&stopOnFirst=false"
    "dna_long_min5_stopFirst|/dna?seq1=seq1:ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGC&seq2=seq2:GCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT&minLength=5&stopOnFirst=true"
)

# ─── Disparar pedidos sequencialmente ──────────────────────────────────────
echo "[bench] Enviar ${#REQUESTS[@]} pedidos sequencialmente..."
for entry in "${REQUESTS[@]}"; do
    label="${entry%%|*}"
    url="${entry#*|}"
    printf "  %-32s ... " "$label"
    start=$(date +%s%N)
    HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 600 "http://localhost:$PORT$url")
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    printf "HTTP %s, wall=%dms\n" "$HTTP" "$elapsed_ms"
done

# Dar tempo ao worker para flush do stdout
sleep 2

# ─── Parse log → CSV ───────────────────────────────────────────────────────
echo
echo "[bench] A extrair métricas do log..."
grep -E "^\[Metrics\]" "$LOG" > "$METRICS_RAW" || true
N_LINES=$(wc -l < "$METRICS_RAW" | tr -d ' ')
echo "[bench] $N_LINES entradas [Metrics] encontradas (esperado: ${#REQUESTS[@]})."

if [ "$N_LINES" -lt "${#REQUESTS[@]}" ]; then
    echo "[WARN] Faltam $((${#REQUESTS[@]} - N_LINES)) entradas. Pode haver buffer não flushed."
fi

# Build CSV
{
    echo "idx,label,requestType,methodCalls,instructions,elapsedMs,paramSummary"
    idx=0
    mapfile -t METRICS_LINES < "$METRICS_RAW"
    for entry in "${REQUESTS[@]}"; do
        label="${entry%%|*}"
        idx=$((idx + 1))
        if [ "$idx" -le "$N_LINES" ]; then
            line="${METRICS_LINES[$((idx - 1))]}"
            requestType=$(echo "$line" | sed -nE 's/^\[Metrics\] \[([^]]+)\].*/\1/p')
            methodCalls=$(echo "$line" | sed -nE 's/.*methods=([0-9]+).*/\1/p')
            instructions=$(echo "$line" | sed -nE 's/.*instructions=([0-9]+).*/\1/p')
            elapsedMs=$(echo "$line" | sed -nE 's/.*time=([0-9]+)ms.*/\1/p')
            # paramSummary: extract params={...} block, replace commas to keep CSV clean
            paramSummary=$(echo "$line" | sed -nE 's/.*params=\{([^}]*)\}.*/\1/p' | tr ',' ';')
        else
            requestType=MISSING
            methodCalls=
            instructions=
            elapsedMs=
            paramSummary=
        fi
        echo "$idx,$label,$requestType,$methodCalls,$instructions,$elapsedMs,\"$paramSummary\""
    done
} > "$CSV"

echo
echo "════════════════════════════════════════════════════════════"
echo "  Benchmark completo!"
echo "    Log:  $LOG"
echo "    CSV:  $CSV"
echo "════════════════════════════════════════════════════════════"
cat "$CSV"
