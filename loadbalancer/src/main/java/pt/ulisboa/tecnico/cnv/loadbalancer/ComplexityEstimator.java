package pt.ulisboa.tecnico.cnv.loadbalancer;

import com.amazonaws.services.dynamodbv2.AmazonDynamoDB;
import com.amazonaws.services.dynamodbv2.AmazonDynamoDBClientBuilder;
import com.amazonaws.services.dynamodbv2.model.AttributeValue;
import com.amazonaws.services.dynamodbv2.model.QueryRequest;
import com.amazonaws.services.dynamodbv2.model.QueryResult;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Estima a complexidade (contagem prevista de instruções bytecode) de um pedido
 * antes de este ser encaminhado para um worker.
 *
 * <p>A unidade da estimativa é <b>instruções bytecode executadas</b> dentro do
 * código instrumentado dos workloads (ICount), correspondente ao campo
 * {@code instructionCount} na tabela DynamoDB. Esta é a métrica primária
 * recolhida pelo {@code JavassistAgent}.
 *
 * <p>Estratégia em 2 camadas:
 * <ol>
 *   <li><b>Histórico do DynamoDB (MSS)</b>: ratio-based estimation
 *       (regressão linear simples) com pedidos passados do mesmo tipo.</li>
 *   <li><b>Heurísticas de fallback</b>: fórmulas baseadas nos parâmetros
 *       quando não há histórico ou o DynamoDB está indisponível.</li>
 * </ol>
 *
 * <p>Os resultados do DynamoDB são cacheados em memória (30s TTL) para evitar
 * que o MSS se torne um gargalo, como avisado no enunciado.
 */
public class ComplexityEstimator {

    private static final String TABLE_NAME = "cnv-metrics";
    private static final long CACHE_TTL_MS = 30_000;
    private static final int MAX_HISTORY_RECORDS = 50;
    private static final long DYNAMODB_RETRY_INTERVAL_MS = 60_000;

    /**
     * DNA feature calibrada em docs/evidence-dna-feature-benchmark.
     * seedPresenceScan estima quanto trabalho findSeed() faz sem repetir a procura
     * O(n1*n2): indexa k-mers de seq2 num HashSet e conta se cada seed de seq1
     * provavelmente força scan completo ou encontra cedo.
     */
    private static final long DNA_MIN_FEATURE = 1L;
    private static final long DNA_CPU_PER_SEED_SCAN = 17L;
    private static final long DNA_CPU_PER_BASE_OUTPUT = 60L;
    private static final long DNA_ALLOC_PER_SEED_SCAN = 52L;
    private static final long DNA_ALLOC_PER_BASE_OUTPUT = 480L;

    /**
     * Pesos para a métrica composta: compositeCost = wCpu * instructionCount + wRam * allocatedBytes.
     * Ambos contribuem linearmente (1 instrução = 1 unidade, 1 byte alocado = 1 unidade).
     * Na prática o ICount domina (~40.000:1 para GrayScott típico) porque estes workloads
     * são CPU-bound por natureza. A RAM torna-se relevante apenas em cenários anómalos
     * (alocações >100MB), funcionando como mecanismo de proteção contra GC pressure.
     * Configuráveis via system properties: -Dcnv.estwork.wcpu=1.0 -Dcnv.estwork.wram=1.0
     */
    private static final double W_CPU = Double.parseDouble(
            System.getProperty("cnv.estwork.wcpu", "1.0"));
    private static final double W_RAM = Double.parseDouble(
            System.getProperty("cnv.estwork.wram", "1.0"));

    private AmazonDynamoDB dynamoDB;
    private boolean available = false;
    private long lastRetryAttemptMs = 0;

    /** Cache local: requestType → histórico recente. */
    private final ConcurrentHashMap<String, CachedHistory> cache = new ConcurrentHashMap<>();

    // ─────────────────────────────────────────────────────────────
    // Estruturas de dados internas
    // ─────────────────────────────────────────────────────────────

    private static class CachedHistory {
        final List<HistoricalRecord> records;
        final long fetchedAt;

        CachedHistory(List<HistoricalRecord> records) {
            this.records = records;
            this.fetchedAt = System.currentTimeMillis();
        }

        boolean isExpired() {
            return System.currentTimeMillis() - fetchedAt > CACHE_TTL_MS;
        }
    }

    private static class HistoricalRecord {
        final Map<String, String> parameters;
        final long instructionCount;
        final long allocatedBytes;

        HistoricalRecord(Map<String, String> parameters, long instructionCount, long allocatedBytes) {
            this.parameters = parameters;
            this.instructionCount = instructionCount;
            this.allocatedBytes = allocatedBytes;
        }
    }

    private static class DnaFeatures {
        final long seedPresenceScan;
        final long sequenceOutputSize;

        DnaFeatures(long seedPresenceScan, long sequenceOutputSize) {
            this.seedPresenceScan = Math.max(DNA_MIN_FEATURE, seedPresenceScan);
            this.sequenceOutputSize = Math.max(1L, sequenceOutputSize);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Resultado da estimativa
    // ─────────────────────────────────────────────────────────────

    public static class Estimate {
        private final long estimatedCost;
        private final String source;

        public Estimate(long estimatedCost, String source) {
            this.estimatedCost = estimatedCost;
            this.source = source;
        }

        /** Custo estimado, em instruções bytecode (ICount). */
        public long getEstimatedCost() { return estimatedCost; }

        /** Origem da estimativa: "history" ou "heuristic". */
        public String getSource() { return source; }

        @Override
        public String toString() {
            return String.format("cost=%d (%s, wCpu=%.2f wRam=%.4f)", estimatedCost, source, W_CPU, W_RAM);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Construtor
    // ─────────────────────────────────────────────────────────────

    public ComplexityEstimator() {
        tryConnect();
    }

    /**
     * Tenta estabelecer ligação ao DynamoDB. Se falhar, agenda retry.
     */
    private void tryConnect() {
        this.lastRetryAttemptMs = System.currentTimeMillis();
        try {
            if (this.dynamoDB == null) {
                this.dynamoDB = AmazonDynamoDBClientBuilder.defaultClient();
            }
            dynamoDB.describeTable(TABLE_NAME);
            this.available = true;
            System.out.println("[ComplexityEstimator] DynamoDB disponível. A usar dados históricos.");
        } catch (Exception e) {
            this.available = false;
            System.err.println("[ComplexityEstimator] DynamoDB indisponível: " + e.getMessage());
            System.err.println("[ComplexityEstimator] A usar apenas heurísticas. Retry em "
                + (DYNAMODB_RETRY_INTERVAL_MS / 1000) + "s.");
        }
    }

    /**
     * Se o DynamoDB não está disponível e já passou o intervalo de retry,
     * tenta reconectar. Chamado em cada {@link #estimate}.
     */
    private void retryIfNeeded() {
        if (!available && System.currentTimeMillis() - lastRetryAttemptMs > DYNAMODB_RETRY_INTERVAL_MS) {
            tryConnect();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // API pública
    // ─────────────────────────────────────────────────────────────

    /**
     * Estima a complexidade de um pedido.
     *
     * @param requestType tipo do pedido: "fractals", "grayscott", "dna"
     * @param parameters  parâmetros do query string (ex: {w=400, h=300, iterations=100})
     * @return estimativa com custo previsto e fonte
     */
    public Estimate estimate(String requestType, Map<String, String> parameters) {
        // Retry ao DynamoDB se necessário (não bloqueia — tenta 1× a cada 60s).
        retryIfNeeded();

        // Tentar estimativa baseada no histórico DynamoDB.
        if (available) {
            long historyEstimate = estimateFromHistory(requestType, parameters);
            if (historyEstimate > 0) {
                return new Estimate(historyEstimate, "history");
            }
        }
        // Fallback: heurísticas baseadas nos parâmetros.
        return new Estimate(estimateFromHeuristics(requestType, parameters), "heuristic");
    }

    public boolean isDynamoDBAvailable() {
        return available;
    }

    // ─────────────────────────────────────────────────────────────
    // Estimativa baseada no histórico (ratio-based)
    // ─────────────────────────────────────────────────────────────

    /**
     * Modelo ratio-based:
     *   1. Para cada pedido histórico, calcula ratio = instructionCount / feature
     *   2. Calcula média dos ratios
     *   3. Estimativa = avgRatio × feature_do_novo_pedido
     *
     * Isto é equivalente a uma regressão linear simples: cost = k × feature
     *
     * Registos do histórico com {@code instructionCount == 0} são saltados
     * (e.g. dados legacy do esquema antigo "basicBlockCount", ou pedidos onde
     * o agente Javassist não correu).
     */
    private long estimateFromHistory(String requestType, Map<String, String> parameters) {
        List<HistoricalRecord> history = getHistory(requestType);
        if (history.isEmpty()) return -1;

        double featureNew = extractFeature(requestType, parameters);
        if (featureNew <= 0) return -1;

        // Ratio-based para ambas as métricas: CPU (ICount) e RAM (allocatedBytes).
        double sumCpuRatios = 0;
        double sumRamRatios = 0;
        int cpuCount = 0;
        int ramCount = 0;
        for (HistoricalRecord rec : history) {
            double featureHist = extractFeature(requestType, rec.parameters);
            if (featureHist > 0) {
                if (rec.instructionCount > 0) {
                    sumCpuRatios += (double) rec.instructionCount / featureHist;
                    cpuCount++;
                }
                if (rec.allocatedBytes > 0) {
                    sumRamRatios += (double) rec.allocatedBytes / featureHist;
                    ramCount++;
                }
            }
        }

        if (cpuCount == 0) return -1;
        double avgCpuRatio = sumCpuRatios / cpuCount;
        long estimatedICount = Math.max(1, (long) (avgCpuRatio * featureNew));

        long estimatedAlloc = 0;
        if (ramCount > 0) {
            double avgRamRatio = sumRamRatios / ramCount;
            estimatedAlloc = Math.max(0, (long) (avgRamRatio * featureNew));
        }

        return compositeCost(estimatedICount, estimatedAlloc);
    }

    /** Calcula a métrica composta: wCpu * instructionCount + wRam * allocatedBytes. */
    private static long compositeCost(long instructionCount, long allocatedBytes) {
        return (long) (W_CPU * instructionCount + W_RAM * Math.max(0, allocatedBytes));
    }

    // ─────────────────────────────────────────────────────────────
    // Extração de features por tipo de workload
    // ─────────────────────────────────────────────────────────────

    /**
     * Cap para o parâmetro {@code iterations} dos fractals.
     * <p>Medições empíricas (2026-05-21, matriz extensiva, ver
     * {@code docs/01.6_calibration_evidence.md}) demonstram que o Julia-set
     * c=(-0.7, 0.6) <b>satura aos ~500 iterações</b>: ICount com iter=500,
     * 1000 ou 2000 é <em>idêntico</em> (140.7M para w=h=400). Todos os pixels
     * que vão escapar já escaparam, e os do "interior" do set continuam até
     * iter, mas são uma fração pequena do trabalho total.
     */
    private static final long FRACTAL_ITER_SATURATION = 500L;

    /**
     * Extrai uma feature numérica dos parâmetros que se correlaciona com a complexidade.
     * A feature é usada tanto para estimar como para calcular ratios do histórico.
     *
     * <p>Calibrado com 33 medições (15 + 18) em 2026-05-21.
     * Ver {@code docs/01.6_calibration_evidence.md} para a análise completa.
     */
    private double extractFeature(String requestType, Map<String, String> parameters) {
        switch (requestType) {
            case "fractals": {
                // Cada pixel corre o loop de iteração da Julia set.
                // CAP iter aos 500 — acima disto, ICount não muda (Julia-set
                // satura, pixels que vão escapar já escaparam).
                double w = parseDouble(parameters, "w", 800);
                double h = parseDouble(parameters, "h", 600);
                double iter = parseDouble(parameters, "iterations", 100);
                double effIter = Math.min(iter, (double) FRACTAL_ITER_SATURATION);
                return w * h * effIter;
            }
            case "grayscott": {
                // Grid NxN onde cada célula é atualizada em cada iteração.
                // Validado empiricamente: ratio 164 instr/cell-iter constante
                // para qualquer dos 3 seedModes válidos (center/ring/stripe
                // tiveram ICount com diferença <0.01% no mesmo size/maxIter).
                // stopOnExtinction também não teve efeito mensurável (mesmo na
                // "death zone" f=0.022/k=0.051 a extinção não disparou).
                double size = parseDouble(parameters, "size", 256);
                double maxIter = parseDouble(parameters, "maxIterations", 5000);
                return size * size * maxIter;
            }
            case "dna": {
                // Ao contrário de fractals/GrayScott, DNA não é bem explicado por
                // max(seq1,seq2) ou seq1*seq2: pedidos com o mesmo tamanho podem
                // variar >100× dependendo de as seeds existirem em seq2. A feature
                // seedPresenceScan aproxima esse comportamento com um HashSet de
                // k-mers de seq2, sem executar o matcher completo.
                return (double) extractDnaFeatures(parameters).seedPresenceScan;
            }
            default:
                return 1.0;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Heurísticas de fallback (sem histórico)
    // ─────────────────────────────────────────────────────────────

    /**
     * Estimativa puramente baseada nos parâmetros, sem dados históricos.
     * Os multiplicadores convertem a feature ("unidades de trabalho lógico")
     * em <b>instruções bytecode</b> esperadas.
     *
     * <p>Calibração 2026-05-21 baseada em 33 medições empíricas observadas
     * localmente (ver {@code docs/01.6_calibration_evidence.md}):
     * <ul>
     *   <li><b>fractals</b>: ratio depende fortemente de iter (Julia-set tem
     *       3 regimes: ramp-up iter&lt;100, transição 100-300, plateau iter≥300).
     *       Heurística usa multiplicador piecewise para cobrir os 3.</li>
     *   <li><b>grayscott</b>: ratio = 164 instr/(célula·iter) com variância
     *       &lt;1% (confirmado em 11 medições cobrindo s64 a s384,
     *       3 seedModes, e f/k diferentes).</li>
     *   <li><b>dna</b>: usa duas dimensões simples: procura de seeds
     *       ({@code seedPresenceScan}) + tamanho de output/parsing
     *       ({@code len(seq1)+len(seq2)}), calibradas em 24 pedidos locais.</li>
     * </ul>
     */
    private long estimateFromHeuristics(String requestType, Map<String, String> parameters) {
        long estimatedICount;
        long estimatedAlloc;
        switch (requestType) {
            case "fractals": {
                long w = parseLong(parameters, "w", 800);
                long h = parseLong(parameters, "h", 600);
                long iter = parseLong(parameters, "iterations", 100);
                long effIter = Math.min(iter, FRACTAL_ITER_SATURATION);
                long multiplier;
                if (iter <= 100) {
                    multiplier = 10;
                } else if (iter <= 300) {
                    multiplier = 5;
                } else {
                    multiplier = 2;
                }
                estimatedICount = w * h * effIter * multiplier;
                // RAM: BufferedImage (w*h*4 bytes ARGB) + objetos temporários.
                // Calibrado empiricamente (2026-06-03): ~33 B/px (ver bench-ram-calibration.csv).
                estimatedAlloc = w * h * 33;
                break;
            }
            case "grayscott": {
                long size = parseLong(parameters, "size", 256);
                long maxIter = parseLong(parameters, "maxIterations", 5000);
                estimatedICount = size * size * maxIter * 164;
                // RAM: 2 grids de doubles + BufferedImage + objetos auxiliares.
                // Calibrado empiricamente (2026-06-03): ~64 B/cell, independente de seedMode e maxIter.
                estimatedAlloc = size * size * 64;
                break;
            }
            case "dna": {
                DnaFeatures f = extractDnaFeatures(parameters);
                // CPU: seedPresenceScan explica os casos caros onde muitas seeds de
                // seq1 não existem em seq2 e findSeed() faz scans completos. O termo
                // sequenceOutputSize cobre parsing, arrays de matched bases e HTML.
                estimatedICount = Math.max(1000,
                        saturatingAdd(
                                saturatingMultiply(f.seedPresenceScan, DNA_CPU_PER_SEED_SCAN),
                                saturatingMultiply(f.sequenceOutputSize, DNA_CPU_PER_BASE_OUTPUT)));
                // RAM: correlaciona com o mesmo trabalho de procura (substrings)
                // mais buffers/HTML proporcionais ao tamanho das sequências.
                estimatedAlloc = saturatingAdd(
                        saturatingMultiply(f.seedPresenceScan, DNA_ALLOC_PER_SEED_SCAN),
                        saturatingMultiply(f.sequenceOutputSize, DNA_ALLOC_PER_BASE_OUTPUT));
                break;
            }
            default:
                estimatedICount = 10000;
                estimatedAlloc = 0;
        }
        return compositeCost(estimatedICount, estimatedAlloc);
    }

    // ─────────────────────────────────────────────────────────────
    // Features específicas do DNA
    // ─────────────────────────────────────────────────────────────

    private DnaFeatures extractDnaFeatures(Map<String, String> parameters) {
        String seq1 = normalizeDnaSequence(parameters.getOrDefault("seq1", "seq1:ATGC"));
        String seq2 = normalizeDnaSequence(parameters.getOrDefault("seq2", "seq2:ATGC"));
        int minLength = (int) Math.max(1L, parseLong(parameters, "minLength", 1));

        long outputSize = (long) seq1.length() + seq2.length();
        long seedPresenceScan = estimateSeedPresenceScan(seq1, seq2, minLength);
        return new DnaFeatures(seedPresenceScan, outputSize);
    }

    private String normalizeDnaSequence(String raw) {
        if (raw == null) return "";
        String decoded;
        try {
            decoded = URLDecoder.decode(raw, StandardCharsets.UTF_8);
        } catch (Exception e) {
            decoded = raw;
        }

        int colon = decoded.indexOf(':');
        String fasta = colon >= 0 ? decoded.substring(colon + 1) : decoded;

        StringBuilder seq = new StringBuilder(fasta.length());
        for (String line : fasta.split("\\n")) {
            String trimmed = line.trim();
            if (!trimmed.isEmpty() && !trimmed.startsWith(">") && !trimmed.startsWith(";")) {
                seq.append(trimmed.toUpperCase());
            }
        }
        return seq.toString();
    }

    private long estimateSeedPresenceScan(String seq1, String seq2, int minLength) {
        if (seq1.length() < minLength || seq2.length() < minLength) {
            return DNA_MIN_FEATURE;
        }

        Set<String> seq2Seeds = new HashSet<>();
        for (int j = 0; j <= seq2.length() - minLength; j++) {
            seq2Seeds.add(seq2.substring(j, j + minLength));
        }

        long fullScan = (long) seq2.length() - minLength + 1;
        long scan = 0;
        for (int i = 0; i <= seq1.length() - minLength; i++) {
            String seed = seq1.substring(i, i + minLength);
            scan = saturatingAdd(scan, seq2Seeds.contains(seed) ? 1L : fullScan);
        }
        return Math.max(DNA_MIN_FEATURE, scan);
    }

    private long saturatingAdd(long a, long b) {
        if (Long.MAX_VALUE - a < b) return Long.MAX_VALUE;
        return a + b;
    }

    private long saturatingMultiply(long a, long b) {
        if (a == 0 || b == 0) return 0;
        if (a > Long.MAX_VALUE / b) return Long.MAX_VALUE;
        return a * b;
    }

    // ─────────────────────────────────────────────────────────────
    // Cache + consulta ao DynamoDB
    // ─────────────────────────────────────────────────────────────

    /**
     * Obtém o histórico de pedidos de um tipo, usando cache com TTL de 30s.
     */
    private List<HistoricalRecord> getHistory(String requestType) {
        CachedHistory cached = cache.get(requestType);
        if (cached != null && !cached.isExpired()) {
            return cached.records;
        }

        try {
            Map<String, AttributeValue> exprValues = new HashMap<>();
            exprValues.put(":rt", new AttributeValue().withS(requestType));

            QueryRequest queryReq = new QueryRequest()
                    .withTableName(TABLE_NAME)
                    .withKeyConditionExpression("requestType = :rt")
                    .withExpressionAttributeValues(exprValues)
                    .withScanIndexForward(false)
                    .withLimit(MAX_HISTORY_RECORDS);

            QueryResult result = dynamoDB.query(queryReq);

            List<HistoricalRecord> records = new ArrayList<>();
            for (Map<String, AttributeValue> item : result.getItems()) {
                Map<String, String> params = new HashMap<>();
                long ic = 0;
                long alloc = 0;

                for (Map.Entry<String, AttributeValue> entry : item.entrySet()) {
                    if (entry.getKey().startsWith("param_") && entry.getValue().getS() != null) {
                        params.put(entry.getKey().substring(6), entry.getValue().getS());
                    }
                    if ("instructionCount".equals(entry.getKey()) && entry.getValue().getN() != null) {
                        ic = Long.parseLong(entry.getValue().getN());
                    }
                    if ("allocatedBytes".equals(entry.getKey()) && entry.getValue().getN() != null) {
                        alloc = Long.parseLong(entry.getValue().getN());
                    }
                }
                records.add(new HistoricalRecord(params, ic, alloc));
            }

            CachedHistory newCache = new CachedHistory(records);
            cache.put(requestType, newCache);
            System.out.println("[ComplexityEstimator] Cache atualizado para '" + requestType
                    + "': " + records.size() + " registos");
            return records;

        } catch (Exception e) {
            System.err.println("[ComplexityEstimator] Erro ao consultar DynamoDB: " + e.getMessage());
            return Collections.emptyList();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Utilitários de parsing
    // ─────────────────────────────────────────────────────────────

    private double parseDouble(Map<String, String> params, String key, double defaultVal) {
        try {
            String val = params.get(key);
            return val != null ? Double.parseDouble(val) : defaultVal;
        } catch (NumberFormatException e) {
            return defaultVal;
        }
    }

    private long parseLong(Map<String, String> params, String key, long defaultVal) {
        try {
            String val = params.get(key);
            return val != null ? Long.parseLong(val) : defaultVal;
        } catch (NumberFormatException e) {
            return defaultVal;
        }
    }
}
