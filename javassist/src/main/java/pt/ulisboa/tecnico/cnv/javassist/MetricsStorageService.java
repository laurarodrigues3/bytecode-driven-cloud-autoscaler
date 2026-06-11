package pt.ulisboa.tecnico.cnv.javassist;

import com.amazonaws.services.dynamodbv2.AmazonDynamoDB;
import com.amazonaws.services.dynamodbv2.AmazonDynamoDBClientBuilder;
import com.amazonaws.services.dynamodbv2.model.AttributeDefinition;
import com.amazonaws.services.dynamodbv2.model.AttributeValue;
import com.amazonaws.services.dynamodbv2.model.BatchWriteItemRequest;
import com.amazonaws.services.dynamodbv2.model.BatchWriteItemResult;
import com.amazonaws.services.dynamodbv2.model.BillingMode;
import com.amazonaws.services.dynamodbv2.model.CreateTableRequest;
import com.amazonaws.services.dynamodbv2.model.KeySchemaElement;
import com.amazonaws.services.dynamodbv2.model.KeyType;
import com.amazonaws.services.dynamodbv2.model.PutRequest;
import com.amazonaws.services.dynamodbv2.model.ResourceInUseException;
import com.amazonaws.services.dynamodbv2.model.ResourceNotFoundException;
import com.amazonaws.services.dynamodbv2.model.ScalarAttributeType;
import com.amazonaws.services.dynamodbv2.model.WriteRequest;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Serviço de armazenamento de métricas no DynamoDB (MSS).
 *
 * Singleton com inicialização lazy. Se as credenciais AWS não estiverem
 * configuradas, o serviço degrada graciosamente — as métricas continuam
 * a ser guardadas localmente no MetricRegistry, apenas sem persistência
 * no DynamoDB.
 *
 * A escrita é assíncrona e agregada em batches periódicos para não bloquear
 * o processamento dos pedidos nem fazer uma chamada DynamoDB por request.
 */
public class MetricsStorageService {

    private static final String TABLE_NAME = "cnv-metrics";
    private static final String PARTITION_KEY = "requestType";
    private static final String SORT_KEY = "requestId";
    private static final int DYNAMODB_BATCH_WRITE_LIMIT = 25;
    private static final int FLUSH_INTERVAL_SECONDS = Integer.parseInt(
            System.getProperty("cnv.metrics.flush.interval.seconds", "15"));
    private static final int MAX_BUFFERED_WRITES = Integer.parseInt(
            System.getProperty("cnv.metrics.max.buffered.writes", "10000"));

    private static MetricsStorageService instance;

    private AmazonDynamoDB dynamoDB;
    private boolean available = false;

    /** Fila de writes pendentes para flush periódico no DynamoDB. */
    private final ConcurrentLinkedQueue<WriteRequest> pendingWrites = new ConcurrentLinkedQueue<>();
    private final AtomicInteger pendingCount = new AtomicInteger(0);

    /** Thread dedicada para flushes periódicos no DynamoDB. */
    private final ScheduledExecutorService flusher = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "MetricsStorage-Flusher");
        t.setDaemon(true);
        return t;
    });

    private MetricsStorageService() {
        try {
            this.dynamoDB = AmazonDynamoDBClientBuilder.defaultClient();
            ensureTableExists();
            this.available = true;
            startFlushLoop();
            System.out.println("[MetricsStorage] DynamoDB disponível. Tabela: " + TABLE_NAME
                    + " (flushInterval=" + FLUSH_INTERVAL_SECONDS + "s)");
        } catch (Exception e) {
            System.err.println("[MetricsStorage] DynamoDB indisponível: " + e.getMessage());
            System.err.println("[MetricsStorage] Métricas serão guardadas apenas localmente.");
        }
    }

    /**
     * Obtém a instância singleton do serviço.
     * A primeira chamada tenta ligar-se ao DynamoDB.
     */
    public static synchronized MetricsStorageService getInstance() {
        if (instance == null) {
            instance = new MetricsStorageService();
        }
        return instance;
    }

    /**
     * Indica se o DynamoDB está acessível e pronto para escrita.
     */
    public boolean isAvailable() {
        return available;
    }

    /**
     * Enfileira as métricas de um pedido concluído para escrita periódica no DynamoDB.
     * Se o DynamoDB não estiver disponível, a chamada é ignorada silenciosamente.
     */
    public void storeAsync(MetricRegistry.CompletedRequest request) {
        if (!available || request == null) return;

        pendingWrites.offer(toWriteRequest(request));
        int size = pendingCount.incrementAndGet();

        // Proteção contra crescimento ilimitado caso o DynamoDB fique lento/indisponível.
        if (size > MAX_BUFFERED_WRITES) {
            WriteRequest dropped = pendingWrites.poll();
            if (dropped != null) {
                pendingCount.decrementAndGet();
                System.err.println("[MetricsStorage] Buffer cheio (" + MAX_BUFFERED_WRITES
                        + "). Métrica mais antiga descartada para proteger memória.");
            }
        }
    }

    /**
     * Inicia o flush periódico de métricas pendentes.
     */
    private void startFlushLoop() {
        flusher.scheduleAtFixedRate(this::flushSafely,
                FLUSH_INTERVAL_SECONDS, FLUSH_INTERVAL_SECONDS, TimeUnit.SECONDS);

        // Melhor esforço para não perder o último batch em encerramento normal da JVM.
        Runtime.getRuntime().addShutdownHook(new Thread(this::flushSafely, "MetricsStorage-ShutdownFlush"));
    }

    private void flushSafely() {
        try {
            flushPendingWrites();
        } catch (Exception e) {
            System.err.println("[MetricsStorage] Erro inesperado no flush: " + e.getMessage());
        }
    }

    /**
     * Escreve métricas pendentes no DynamoDB em batches de até 25 items.
     */
    private synchronized void flushPendingWrites() {
        if (!available || pendingCount.get() == 0) return;

        int flushed = 0;
        while (pendingCount.get() > 0) {
            List<WriteRequest> batch = drainBatch();
            if (batch.isEmpty()) break;

            try {
                List<WriteRequest> unprocessed = writeBatchWithRetries(batch);
                flushed += batch.size() - unprocessed.size();
                if (!unprocessed.isEmpty()) {
                    requeue(unprocessed);
                    break;
                }
            } catch (Exception e) {
                if (e instanceof InterruptedException) {
                    Thread.currentThread().interrupt();
                }
                requeue(batch);
                System.err.println("[MetricsStorage] Erro ao fazer batch write: " + e.getMessage()
                        + ". Batch re-enfileirado.");
                break;
            }
        }

        if (flushed > 0) {
            System.out.println("[MetricsStorage] Flush DynamoDB: " + flushed
                    + " métricas escritas; pendentes=" + pendingCount.get());
        }
    }

    private List<WriteRequest> drainBatch() {
        List<WriteRequest> batch = new ArrayList<>(DYNAMODB_BATCH_WRITE_LIMIT);
        for (int i = 0; i < DYNAMODB_BATCH_WRITE_LIMIT; i++) {
            WriteRequest wr = pendingWrites.poll();
            if (wr == null) break;
            pendingCount.decrementAndGet();
            batch.add(wr);
        }
        return batch;
    }

    private List<WriteRequest> writeBatchWithRetries(List<WriteRequest> batch) throws InterruptedException {
        Map<String, List<WriteRequest>> requestItems = new HashMap<>();
        requestItems.put(TABLE_NAME, batch);

        for (int attempt = 0; attempt < 3; attempt++) {
            BatchWriteItemResult result = dynamoDB.batchWriteItem(
                    new BatchWriteItemRequest().withRequestItems(requestItems));
            requestItems = result.getUnprocessedItems();

            List<WriteRequest> unprocessed = requestItems == null ? null : requestItems.get(TABLE_NAME);
            if (unprocessed == null || unprocessed.isEmpty()) {
                return new ArrayList<>();
            }

            Thread.sleep(100L * (1L << attempt));
        }

        List<WriteRequest> unprocessed = requestItems == null ? null : requestItems.get(TABLE_NAME);
        return unprocessed == null ? new ArrayList<>() : unprocessed;
    }

    private void requeue(List<WriteRequest> writes) {
        for (WriteRequest wr : writes) {
            pendingWrites.offer(wr);
            pendingCount.incrementAndGet();
        }
    }

    /**
     * Converte um CompletedRequest num PutRequest para BatchWriteItem.
     */
    private WriteRequest toWriteRequest(MetricRegistry.CompletedRequest request) {
        Map<String, AttributeValue> item = new HashMap<>();

        // Chaves primárias
        item.put(PARTITION_KEY, new AttributeValue().withS(request.getRequestType()));
        item.put(SORT_KEY, new AttributeValue().withS(
                request.getTimestamp() + "_" + UUID.randomUUID().toString().substring(0, 8)));

        // Métricas (guardadas como Number para permitir queries/aggregations).
        //   - instructionCount  → métrica primária (ICount); usada pelo ComplexityEstimator.
        //   - methodCallCount   → métrica secundária (cross-check / diagnóstico).
        //   - allocatedBytes    → pressão de memória medida por ThreadMXBean.
        //   - elapsedTimeMs     → métrica de validação (correlação com ICount estimado).
        // NOTA: o campo legado "basicBlockCount" foi descontinuado em 2026-05-21
        // (ver docs/01.5_icount_migration.md). Registos antigos com esse campo
        // são ignorados pelo estimador.
        item.put("methodCallCount", new AttributeValue().withN(
                String.valueOf(request.getMethodCallCount())));
        item.put("instructionCount", new AttributeValue().withN(
                String.valueOf(request.getInstructionCount())));
        item.put("allocatedBytes", new AttributeValue().withN(
                String.valueOf(request.getAllocatedBytes())));
        item.put("elapsedTimeMs", new AttributeValue().withN(
                String.valueOf(request.getElapsedTimeMs())));
        item.put("timestamp", new AttributeValue().withN(
                String.valueOf(request.getTimestamp())));

        // Parâmetros do pedido (prefixados com param_ para evitar colisões)
        for (Map.Entry<String, String> entry : request.getParameters().entrySet()) {
            item.put("param_" + entry.getKey(), new AttributeValue().withS(entry.getValue()));
        }

        return new WriteRequest().withPutRequest(new PutRequest().withItem(item));
    }

    /**
     * Cria a tabela DynamoDB se não existir.
     * Usa PAY_PER_REQUEST (on-demand) para evitar configuração de throughput.
     */
    private void ensureTableExists() {
        try {
            dynamoDB.describeTable(TABLE_NAME);
            // Tabela já existe.
        } catch (ResourceNotFoundException e) {
            System.out.println("[MetricsStorage] A criar tabela DynamoDB: " + TABLE_NAME);

            CreateTableRequest req = new CreateTableRequest()
                    .withTableName(TABLE_NAME)
                    .withKeySchema(
                            new KeySchemaElement(PARTITION_KEY, KeyType.HASH),
                            new KeySchemaElement(SORT_KEY, KeyType.RANGE))
                    .withAttributeDefinitions(
                            new AttributeDefinition(PARTITION_KEY, ScalarAttributeType.S),
                            new AttributeDefinition(SORT_KEY, ScalarAttributeType.S))
                    .withBillingMode(BillingMode.PAY_PER_REQUEST);

            try {
                dynamoDB.createTable(req);
            } catch (ResourceInUseException raceWinner) {
                // Outro worker em paralelo já lançou createTable — não é erro.
                System.out.println("[MetricsStorage] Tabela a ser criada por outro processo — a aguardar.");
            }

            // Esperar até a tabela ficar ACTIVE (máximo ~30s).
            waitForTableActive();
        }
    }

    /**
     * Espera até a tabela ficar no estado ACTIVE (polling simples).
     */
    private void waitForTableActive() {
        try {
            for (int i = 0; i < 30; i++) {
                String status = dynamoDB.describeTable(TABLE_NAME)
                        .getTable().getTableStatus();
                if ("ACTIVE".equals(status)) {
                    System.out.println("[MetricsStorage] Tabela " + TABLE_NAME + " está ACTIVE.");
                    return;
                }
                Thread.sleep(1000);
            }
            System.err.println("[MetricsStorage] Timeout à espera que a tabela ficasse ACTIVE.");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
