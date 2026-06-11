package pt.ulisboa.tecnico.cnv.javassist;

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentLinkedDeque;

import com.sun.management.ThreadMXBean;

/**
 * Thread-local metric collection for instrumented request handling.
 * Each worker thread accumulates metrics during request processing.
 */
public class MetricRegistry {

    private static final int MAX_COMPLETED_METRICS = 1000;

    /**
     * Immutable snapshot of a completed request's metrics.
     * Created at the end of each request for storage and analysis.
     */
    public static class CompletedRequest {
        private final String requestType;
        private final Map<String, String> parameters;
        private final long methodCallCount;
        private final long instructionCount;
        private final long allocatedBytes;
        private final long elapsedTimeMs;
        private final long timestamp;

        public CompletedRequest(String requestType, Map<String, String> parameters,
                                long methodCallCount, long instructionCount,
                                long allocatedBytes, long elapsedTimeMs, long timestamp) {
            this.requestType = requestType;
            this.parameters = Collections.unmodifiableMap(new HashMap<>(parameters));
            this.methodCallCount = methodCallCount;
            this.instructionCount = instructionCount;
            this.allocatedBytes = allocatedBytes;
            this.elapsedTimeMs = elapsedTimeMs;
            this.timestamp = timestamp;
        }

        public String getRequestType() { return requestType; }
        public Map<String, String> getParameters() { return parameters; }
        public long getMethodCallCount() { return methodCallCount; }
        /** Bytecode instructions executed inside the instrumented packages (CPU metric). */
        public long getInstructionCount() { return instructionCount; }
        /** Bytes allocated by this thread during request processing (RAM metric). */
        public long getAllocatedBytes() { return allocatedBytes; }
        public long getElapsedTimeMs() { return elapsedTimeMs; }
        public long getTimestamp() { return timestamp; }

        /**
         * Returns a flat map representation suitable for DynamoDB or serialization.
         * Parameter keys are prefixed with "param_" to avoid collisions with metric keys.
         */
        public Map<String, String> toMap() {
            Map<String, String> map = new HashMap<>();
            map.put("requestType", requestType);
            map.put("methodCallCount", String.valueOf(methodCallCount));
            map.put("instructionCount", String.valueOf(instructionCount));
            map.put("allocatedBytes", String.valueOf(allocatedBytes));
            map.put("elapsedTimeMs", String.valueOf(elapsedTimeMs));
            map.put("timestamp", String.valueOf(timestamp));
            for (Map.Entry<String, String> entry : parameters.entrySet()) {
                map.put("param_" + entry.getKey(), entry.getValue());
            }
            return map;
        }

        @Override
        public String toString() {
            return String.format("[%s] params=%s, methods=%d, instructions=%d, alloc=%dB, time=%dms",
                    requestType, parameters, methodCallCount, instructionCount, allocatedBytes, elapsedTimeMs);
        }
    }

    /**
     * Holds per-request metrics for the current thread (mutable accumulator).
     * Reused across requests on the same thread via reset().
     */
    public static class RequestMetrics {
        private long methodCallCount = 0;
        private long instructionCount = 0;
        private long allocatedBytesBefore = 0;
        private long startTime = 0;
        private String requestType = "";
        private Map<String, String> parameters = new HashMap<>();

        /**
         * Resets all counters and parses the URI into requestType + parameters.
         * Called at the start of each request.
         *
         * @param uri the full request URI, e.g. "/fractals?w=400&h=300&iterations=100"
         */
        public void reset(String uri) {
            this.methodCallCount = 0;
            this.instructionCount = 0;
            this.startTime = System.nanoTime();
            this.allocatedBytesBefore = getAllocatedBytesNow();
            parseUri(uri);
        }

        private static long getAllocatedBytesNow() {
            try {
                ThreadMXBean tmxb = (ThreadMXBean) ManagementFactory.getThreadMXBean();
                if (tmxb.isThreadAllocatedMemorySupported() && tmxb.isThreadAllocatedMemoryEnabled()) {
                    return tmxb.getThreadAllocatedBytes(Thread.currentThread().getId());
                }
            } catch (Exception ignored) {}
            return -1;
        }

        private void parseUri(String uri) {
            this.parameters = new HashMap<>();
            if (uri == null || uri.isEmpty()) {
                this.requestType = "unknown";
                return;
            }

            // Split path and query: "/fractals?w=400&h=300"
            int queryStart = uri.indexOf('?');
            String path = queryStart >= 0 ? uri.substring(0, queryStart) : uri;
            String query = queryStart >= 0 ? uri.substring(queryStart + 1) : null;

            // Extract request type from path (remove leading /)
            this.requestType = path.startsWith("/") ? path.substring(1) : path;
            if (this.requestType.isEmpty()) {
                this.requestType = "root";
            }

            // Parse query parameters
            if (query != null && !query.isEmpty()) {
                for (String param : query.split("&")) {
                    String[] kv = param.split("=", 2);
                    if (kv.length == 2) {
                        this.parameters.put(kv[0], kv[1]);
                    } else if (kv.length == 1) {
                        this.parameters.put(kv[0], "");
                    }
                }
            }
        }

        public long getMethodCallCount() { return methodCallCount; }
        public long getInstructionCount() { return instructionCount; }
        public String getRequestType() { return requestType; }
        public Map<String, String> getParameters() { return parameters; }
        public long getElapsedTimeMs() { return (System.nanoTime() - startTime) / 1_000_000; }

        /** Bytes allocated by this thread during request processing. -1 if unavailable. */
        public long getAllocatedBytes() {
            if (allocatedBytesBefore < 0) return -1;
            long now = getAllocatedBytesNow();
            if (now < 0) return -1;
            return now - allocatedBytesBefore;
        }

        /**
         * Creates an immutable snapshot of the current metrics.
         */
        public CompletedRequest snapshot() {
            return new CompletedRequest(
                    requestType,
                    parameters,
                    methodCallCount,
                    instructionCount,
                    getAllocatedBytes(),
                    getElapsedTimeMs(),
                    System.currentTimeMillis()
            );
        }

        @Override
        public String toString() {
            return String.format("[%s] params=%s, methods=%d, instructions=%d, alloc=%dB, time=%dms",
                    requestType, parameters, methodCallCount, instructionCount, getAllocatedBytes(), getElapsedTimeMs());
        }
    }

    private static final ThreadLocal<RequestMetrics> threadMetrics =
            ThreadLocal.withInitial(RequestMetrics::new);

    /**
     * Storage for completed request metrics (bounded, newest first).
     */
    private static final ConcurrentLinkedDeque<CompletedRequest> completedMetrics = new ConcurrentLinkedDeque<>();

    /**
     * Called at the start of request handling (e.g., handle() method entry).
     */
    public static void startRequest(String uri) {
        threadMetrics.get().reset(uri);
    }

    /**
     * Called by instrumented code at each method entry.
     * <p>Secondary / cross-check metric. Useful for diagnosing irregularities
     * between {@link #incrementInstructions(long)} ratios across requests.
     */
    public static void incrementMethodCalls() {
        threadMetrics.get().methodCallCount++;
    }

    /**
     * Called by instrumented code at the entry of each basic block, with the
     * number of bytecode instructions inside that block as the {@code count}.
     *
     * <p><b>Primary complexity metric (ICount).</b> Captures the dynamic execution
     * of the workload: each loop iteration enters its body block once, contributing
     * its instruction count. The accumulated value scales with the actual work
     * performed, which is exactly what is needed to estimate request complexity.
     */
    public static void incrementInstructions(long count) {
        threadMetrics.get().instructionCount += count;
    }

    /**
     * Called at the end of request handling. Logs and stores the metrics snapshot.
     * Also persists to DynamoDB asynchronously (if available).
     */
    public static void stopRequest() {
        RequestMetrics m = threadMetrics.get();
        CompletedRequest snapshot = m.snapshot();
        System.out.println("[Metrics] " + snapshot);

        // Store locally (in-memory, bounded).
        completedMetrics.addFirst(snapshot);
        while (completedMetrics.size() > MAX_COMPLETED_METRICS) {
            completedMetrics.pollLast();
        }

        // Persist to DynamoDB (async, no-op if unavailable).
        MetricsStorageService.getInstance().storeAsync(snapshot);
    }

    /**
     * Returns the current thread's metrics (for inspection/debugging).
     */
    public static RequestMetrics getCurrentMetrics() {
        return threadMetrics.get();
    }

    /**
     * Returns all completed metrics as a list (newest first).
     */
    public static List<CompletedRequest> getCompletedMetrics() {
        return new ArrayList<>(completedMetrics);
    }

    /**
     * Returns completed metrics filtered by request type (e.g., "fractals", "dna", "grayscott").
     */
    public static List<CompletedRequest> getCompletedMetricsByType(String requestType) {
        List<CompletedRequest> filtered = new ArrayList<>();
        for (CompletedRequest cr : completedMetrics) {
            if (cr.getRequestType().equals(requestType)) {
                filtered.add(cr);
            }
        }
        return filtered;
    }

    /**
     * Clears all completed metrics.
     */
    public static void clearCompletedMetrics() {
        completedMetrics.clear();
    }
}
