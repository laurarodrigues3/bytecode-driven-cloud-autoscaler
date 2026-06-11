package pt.ulisboa.tecnico.cnv.loadbalancer;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * Load Balancer — entry point of the Nature@Cloud system.
 * Receives all HTTP requests and forwards them to available workers.
 * Also runs the Auto Scaler in a background thread.
 *
 * Usage: java LoadBalancer [lb_port] [worker_host:port ...]
 * Example: java LoadBalancer 8080 localhost:8001 localhost:8002
 */
public class LoadBalancer {

    private static final int DEFAULT_PORT = 8080;
    private static final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private final WorkerPool workerPool;
    private final AutoScaler autoScaler;
    private final ComplexityEstimator complexityEstimator;
    private final LambdaInvoker lambdaInvoker;

    /** Max estimated wall-clock seconds for a request to be Lambda-eligible. */
    static final double LAMBDA_MAX_SECONDS = Double.parseDouble(
            System.getProperty("cnv.lambda.maxseconds", "5.0"));

    /** Workers above this fraction of MAX_CAPACITY are considered "busy" for Lambda routing. */
    static final double WORKER_LOAD_THRESHOLD = Double.parseDouble(
            System.getProperty("cnv.lambda.loadthreshold", "0.80"));

    public LoadBalancer(WorkerPool workerPool) {
        this.workerPool = workerPool;
        this.autoScaler = new AutoScaler(workerPool);
        this.complexityEstimator = new ComplexityEstimator();
        this.lambdaInvoker = LambdaInvoker.getInstance();
    }

    public void start(int port) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.setExecutor(Executors.newCachedThreadPool());
        server.createContext("/", new ForwardHandler());
        server.start();

        System.out.println("[LoadBalancer] Listening on port " + port);
        System.out.println("[LoadBalancer] Workers: " + workerPool.size());

        // Start auto scaler + worker health checks in background.
        autoScaler.start();
        workerPool.startHealthChecks();
    }

    /**
     * Handler that forwards requests to workers.
     */
    private class ForwardHandler implements HttpHandler {

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            // Handling CORS.
            exchange.getResponseHeaders().add("Access-Control-Allow-Origin", "*");
            if ("OPTIONS".equalsIgnoreCase(exchange.getRequestMethod())) {
                exchange.getResponseHeaders().add("Access-Control-Allow-Methods", "GET, OPTIONS");
                exchange.getResponseHeaders().add("Access-Control-Allow-Headers", "Content-Type,Authorization");
                exchange.sendResponseHeaders(204, -1);
                return;
            }

            String path = exchange.getRequestURI().getRawPath();
            String query = exchange.getRequestURI().getRawQuery();

            // Only forward workload paths.
            if (!path.equals("/fractals") && !path.equals("/dna") && !path.equals("/grayscott")) {
                String msg = "Load Balancer - Nature@Cloud\nWorkers: " + workerPool.size() + "\n";
                for (WorkerPool.Worker w : workerPool.getWorkers()) {
                    msg += "  " + w.toString() + "\n";
                }
                byte[] bytes = msg.getBytes();
                exchange.sendResponseHeaders(200, bytes.length);
                OutputStream os = exchange.getResponseBody();
                os.write(bytes);
                os.close();
                return;
            }

            // Estimate request complexity before forwarding.
            String requestType = path.substring(1); // remove leading /
            Map<String, String> params = parseQuery(query);
            ComplexityEstimator.Estimate estimate = complexityEstimator.estimate(requestType, params);
            long estimatedCost = estimate.getEstimatedCost();
            double estimatedCostSeconds = estimatedCost / (WorkerPool.WORKER_THROUGHPUT_INSTR_PER_MS * 1000.0);
            System.out.println("[LoadBalancer] Complexity estimate for " + path + ": " + estimate
                    + String.format(" (%.2fs)", estimatedCostSeconds));

            // Lambda fast-path: if all workers are busy AND request is small enough,
            // skip EC2 entirely and go directly to Lambda.
            if (estimatedCostSeconds <= LAMBDA_MAX_SECONDS && lambdaInvoker.isAvailable()) {
                if (allWorkersBusy()) {
                    System.out.println("[LoadBalancer] All workers busy (>" + (int)(WORKER_LOAD_THRESHOLD*100)
                            + "%) + request Lambda-eligible — routing directly to Lambda.");
                    try {
                        String lambdaResponse = lambdaInvoker.invoke(requestType, params);
                        byte[] body = lambdaResponse.getBytes();
                        exchange.sendResponseHeaders(200, body.length);
                        OutputStream os = exchange.getResponseBody();
                        os.write(body);
                        os.close();
                        return;
                    } catch (Exception e) {
                        System.err.println("[LoadBalancer] Lambda fast-path failed: " + e.getMessage());
                        // Fall through to EC2 attempt.
                    }
                }
            }

            // Try forwarding with retry on failure. Hybrid placement strategy:
            // packing within MAX_CAPACITY, spreading as fallback. See
            // docs/02.1_lb_packing_strategy.md for the rationale.
            int maxRetries = Math.min(3, workerPool.size());
            java.util.Set<WorkerPool.Worker> triedWorkers = new java.util.HashSet<>();
            boolean success = false;

            for (int attempt = 0; attempt < maxRetries && !success; attempt++) {
                // Cost-aware hybrid selection (packing/spreading) excluding workers
                // already tried in previous attempts.
                WorkerPool.Worker worker = workerPool.selectForRequest(estimatedCost, triedWorkers);
                if (worker == null) {
                    break;
                }
                triedWorkers.add(worker);

                // Build target URL.
                String targetUrl = worker.getBaseUrl() + path;
                if (query != null && !query.isEmpty()) {
                    targetUrl += "?" + query;
                }

                System.out.println("[LoadBalancer] Forwarding " + path + " -> " + worker + " (attempt " + (attempt + 1) + ")");

                worker.incrementActive();
                worker.addEstimatedWork(estimatedCost);
                try {
                    HttpRequest request = HttpRequest.newBuilder()
                            .uri(URI.create(targetUrl))
                            .timeout(Duration.ofSeconds(120))
                            .GET()
                            .build();

                    HttpResponse<byte[]> response = httpClient.send(request, HttpResponse.BodyHandlers.ofByteArray());

                    // Return worker's response to client.
                    byte[] body = response.body();
                    exchange.sendResponseHeaders(response.statusCode(), body.length);
                    OutputStream os = exchange.getResponseBody();
                    os.write(body);
                    os.close();
                    success = true;

                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    sendError(exchange, 500, "Request interrupted");
                    return;
                } catch (Exception e) {
                    System.err.println("[LoadBalancer] Worker " + worker + " failed: " + e.getMessage());
                } finally {
                    worker.removeEstimatedWork(estimatedCost);
                    worker.decrementActive();
                }
            }

            if (!success) {
                // Lambda fallback: if EC2 retries exhausted and request is Lambda-eligible,
                // try Lambda as a last resort (fault tolerance).
                if (estimatedCostSeconds <= LAMBDA_MAX_SECONDS && lambdaInvoker.isAvailable()) {
                    System.out.println("[LoadBalancer] EC2 retries exhausted — falling back to Lambda.");
                    try {
                        String lambdaResponse = lambdaInvoker.invoke(requestType, params);
                        byte[] body = lambdaResponse.getBytes();
                        exchange.sendResponseHeaders(200, body.length);
                        OutputStream os = exchange.getResponseBody();
                        os.write(body);
                        os.close();
                        return;
                    } catch (Exception e) {
                        System.err.println("[LoadBalancer] Lambda fallback also failed: " + e.getMessage());
                    }
                }
                sendError(exchange, 502, "All workers unreachable after " + maxRetries + " attempts");
            }
        }

        /**
         * Returns true if ALL workers are above WORKER_LOAD_THRESHOLD of MAX_CAPACITY.
         * Used to decide whether to route directly to Lambda.
         */
        private boolean allWorkersBusy() {
            // Empty pool → treat as "all busy" so Lambda fast-path triggers.
            // The fallback would catch this anyway, but fast-path avoids unnecessary EC2 attempts.
            if (workerPool.getWorkers().isEmpty()) {
                return true;
            }
            long capacity = WorkerPool.DEFAULT_MAX_CAPACITY;
            long busyThreshold = (long) (capacity * WORKER_LOAD_THRESHOLD);
            for (WorkerPool.Worker w : workerPool.getWorkers()) {
                if (w.getEstimatedWork() < busyThreshold) {
                    return false;
                }
            }
            return true;
        }

        private Map<String, String> parseQuery(String query) {
            Map<String, String> result = new HashMap<>();
            if (query == null || query.isEmpty()) return result;
            for (String param : query.split("&")) {
                String[] kv = param.split("=", 2);
                if (kv.length == 2) {
                    result.put(kv[0], kv[1]);
                } else if (kv.length == 1) {
                    result.put(kv[0], "");
                }
            }
            return result;
        }

        private void sendError(HttpExchange exchange, int code, String message) throws IOException {
            String error = "{ \"error\": \"" + message + "\" }";
            byte[] bytes = error.getBytes();
            exchange.sendResponseHeaders(code, bytes.length);
            OutputStream os = exchange.getResponseBody();
            os.write(bytes);
            os.close();
        }
    }

    public static void main(String[] args) throws Exception {
        int port = DEFAULT_PORT;
        WorkerPool pool = new WorkerPool();

        if (args.length >= 1) {
            port = Integer.parseInt(args[0]);
        }

        // Remaining args are worker addresses (host:port).
        if (args.length >= 2) {
            for (int i = 1; i < args.length; i++) {
                String[] parts = args[i].split(":");
                String host = parts[0];
                int workerPort = Integer.parseInt(parts[1]);
                pool.addWorker(host, workerPort);
            }
        } else if (AwsConfig.isAwsScalingEnabled()) {
            // AWS mode sem args: pool arranca vazio. O AutoScaler vai descobrir
            // workers existentes (discoverExistingWorkers) e/ou criar novos.
            System.out.println("[LoadBalancer] AWS mode: pool inicial vazio. "
                    + "AutoScaler vai descobrir/provisionar workers.");
        } else {
            // Local-dev fallback: 1 worker em localhost:8000.
            pool.addWorker("localhost", 8000);
        }

        LoadBalancer lb = new LoadBalancer(pool);
        lb.start(port);
    }
}
