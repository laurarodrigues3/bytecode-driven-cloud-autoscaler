#!/usr/bin/env bash
# Benchmark de calibração estendido.
#
# Cobre os pontos fracos identificados na primeira ronda de calibração:
#   1) Fractals: confirmar/refutar power-law `iter` (5 pontos com iter isolado).
#   2) Fractals: w/h escala isolada (3 pontos com iter=100 fixo).
#   3) GrayScott: comparar os 3 seedModes VÁLIDOS (center/ring/stripe).
#   4) GrayScott: efeito real de stopOnExtinction com f/k que dispara extinção
#      (f=0.022, k=0.051 = região "death" do espaço de parâmetros).
#   5) Pedidos heavy próximos de 10¹⁰-10¹¹ instructions para validar MAX_CAPACITY.
#   6) DNA com sequências longas (200, 500 chars) para validar escala.

set -euo pipefail
trap '' HUP
cd "$(dirname "$0")/../.."

PORT=8000
LOG=bench-ext-worker.log
CSV=bench-ext.csv
METRICS_RAW=bench-ext-metrics-lines.txt

JAR_AGENT="javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
JAR_WS="webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

if [ ! -f "$JAR_AGENT" ] || [ ! -f "$JAR_WS" ]; then
    echo "[ERRO] JARs não encontrados. Correr primeiro:"
    echo "       mvn -q package -DskipTests"
    exit 1
fi

WORKER_PID=""
cleanup() {
    if [ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null; then
        echo
        echo "[cleanup] A parar worker PID $WORKER_PID..."
        kill "$WORKER_PID" 2>/dev/null || true
        for i in 1 2 3 4 5; do
            kill -0 "$WORKER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$WORKER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[bench-ext] A limpar possíveis workers órfãos na porta $PORT..."
pkill -f "WebServer $PORT" 2>/dev/null || true
sleep 1

echo "[bench-ext] A arrancar worker na porta $PORT..."
rm -f "$LOG" "$METRICS_RAW" "$CSV"
java -javaagent:"$JAR_AGENT" -cp "$JAR_WS" \
     pt.ulisboa.tecnico.cnv.webserver.WebServer "$PORT" \
     >"$LOG" 2>&1 &
WORKER_PID=$!
echo "[bench-ext] Worker PID=$WORKER_PID, log=$LOG"

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/" 2>/dev/null; then
        echo "[bench-ext] Worker pronto."
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

# Geradores de sequências longas para DNA (apenas A/C/G/T).
# Sequência base de 50 chars; replicada para chegar a tamanhos maiores.
DNA50="ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT"
DNA200="${DNA50}${DNA50}${DNA50}${DNA50}"                     # 200 chars
DNA500="${DNA200}${DNA200}${DNA50}${DNA50}"                   # 500 chars

REQUESTS=(
    # ─────────────────────────────────────────────────────────────────────
    # Bloco 1 — Fractals com `iter` ISOLADO (w=400, h=400 fixos)
    # Objectivo: ver como ICount escala com iter; testar a power-law iter^0.18.
    # ─────────────────────────────────────────────────────────────────────
    "frac_iter_50|/fractals?w=400&h=400&iterations=50"
    "frac_iter_200|/fractals?w=400&h=400&iterations=200"
    "frac_iter_500|/fractals?w=400&h=400&iterations=500"
    "frac_iter_1000|/fractals?w=400&h=400&iterations=1000"
    "frac_iter_2000|/fractals?w=400&h=400&iterations=2000"

    # ─────────────────────────────────────────────────────────────────────
    # Bloco 2 — Fractals com `w*h` ISOLADO (iter=100 fixo)
    # Objectivo: confirmar que w*h escala linearmente (deve dar ratio ~constante).
    # ─────────────────────────────────────────────────────────────────────
    "frac_wh_90k|/fractals?w=300&h=300&iterations=100"
    "frac_wh_480k|/fractals?w=800&h=600&iterations=100"
    "frac_wh_1.92M|/fractals?w=1600&h=1200&iterations=100"

    # ─────────────────────────────────────────────────────────────────────
    # Bloco 3 — GrayScott com os 3 seedModes VÁLIDOS (size=128, maxIter=2000)
    # Objectivo: testar se ring/stripe têm ICount diferente de center.
    # ─────────────────────────────────────────────────────────────────────
    "gs_s128_center|/grayscott?size=128&maxIterations=2000&stopOnExtinction=false&seedMode=center"
    "gs_s128_ring|/grayscott?size=128&maxIterations=2000&stopOnExtinction=false&seedMode=ring"
    "gs_s128_stripe|/grayscott?size=128&maxIterations=2000&stopOnExtinction=false&seedMode=stripe"

    # ─────────────────────────────────────────────────────────────────────
    # Bloco 4 — GrayScott com f/k que dispara extinção (size=64, maxIter=2000)
    # Objectivo: validar se stopOnExtinction tem efeito DETECTÁVEL quando f/k
    # leva a extinção real (f=0.022, k=0.051 são valores "death zone").
    # ─────────────────────────────────────────────────────────────────────
    "gs_death_run|/grayscott?size=64&maxIterations=2000&f=0.022&k=0.051&stopOnExtinction=false&seedMode=center"
    "gs_death_stop|/grayscott?size=64&maxIterations=2000&f=0.022&k=0.051&stopOnExtinction=true&seedMode=center"

    # ─────────────────────────────────────────────────────────────────────
    # Bloco 5 — Pedidos HEAVY (~10¹⁰-10¹¹ instructions)
    # Objectivo: validar/refutar a extrapolação MAX_CAPACITY = 5×10¹⁰.
    # Fractals 1500²×1000 ≈ 2.25×10⁹ feature × ~2 ratio (extrapolado) ≈ 4×10⁹.
    # GrayScott 384×2000 = 2.95×10⁸ feature × 164 = 4.84×10¹⁰.
    # ─────────────────────────────────────────────────────────────────────
    "frac_heavy_1500|/fractals?w=1500&h=1500&iterations=1000"
    "gs_heavy_s384|/grayscott?size=384&maxIterations=2000&stopOnExtinction=false&seedMode=center"

    # ─────────────────────────────────────────────────────────────────────
    # Bloco 6 — DNA com sequências longas
    # Objectivo: validar escala em comprimento realista de seq.
    # ─────────────────────────────────────────────────────────────────────
    "dna_200|/dna?seq1=s1:${DNA200}&seq2=s2:${DNA200}&minLength=3&stopOnFirst=false"
    "dna_500|/dna?seq1=s1:${DNA500}&seq2=s2:${DNA500}&minLength=3&stopOnFirst=false"
    "dna_500_stopFirst|/dna?seq1=s1:${DNA500}&seq2=s2:${DNA500}&minLength=3&stopOnFirst=true"
)

echo "[bench-ext] A enviar ${#REQUESTS[@]} pedidos sequencialmente..."
for entry in "${REQUESTS[@]}"; do
    label="${entry%%|*}"
    url="${entry#*|}"
    printf "  %-22s ... " "$label"
    start=$(date +%s%N)
    HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 600 "http://localhost:$PORT$url")
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    printf "HTTP %s, wall=%dms\n" "$HTTP" "$elapsed_ms"
done

sleep 2

echo
echo "[bench-ext] A extrair métricas do log..."
grep -E "^\[Metrics\]" "$LOG" > "$METRICS_RAW" || true
N_LINES=$(wc -l < "$METRICS_RAW" | tr -d ' ')
echo "[bench-ext] $N_LINES entradas [Metrics] (esperado: ${#REQUESTS[@]})."

if [ "$N_LINES" -lt "${#REQUESTS[@]}" ]; then
    echo "[WARN] Faltam $((${#REQUESTS[@]} - N_LINES)) entradas."
fi

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
echo "  Benchmark estendido completo!"
echo "    Log:  $LOG"
echo "    CSV:  $CSV"
echo "════════════════════════════════════════════════════════════"
cat "$CSV"
