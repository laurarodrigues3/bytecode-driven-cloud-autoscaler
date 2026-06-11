package pt.ulisboa.tecnico.cnv.loadbalancer;

import com.amazonaws.services.lambda.AWSLambda;
import com.amazonaws.services.lambda.AWSLambdaClientBuilder;
import com.amazonaws.services.lambda.model.InvokeRequest;
import com.amazonaws.services.lambda.model.InvokeResult;

import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Invokes AWS Lambda functions for small/medium requests.
 * Singleton — initialized lazily on first use.
 *
 * <p>Lambda functions are deployed via {@code scripts/06-deploy-lambdas.sh}
 * and follow the naming convention {@code cnv-<workload>}.
 */
public class LambdaInvoker {

    private static final Map<String, String> FUNCTION_NAMES = Map.of(
            "fractals", "cnv-fractals",
            "grayscott", "cnv-grayscott",
            "dna", "cnv-dna"
    );

    private static volatile LambdaInvoker instance;
    private final AWSLambda lambdaClient;
    private final boolean available;

    private LambdaInvoker() {
        boolean avail = false;
        AWSLambda client = null;
        try {
            client = AWSLambdaClientBuilder.defaultClient();
            avail = true;
            System.out.println("[LambdaInvoker] AWS Lambda client inicializado.");
        } catch (Exception e) {
            System.err.println("[LambdaInvoker] AWS Lambda indisponivel: " + e.getMessage());
        }
        this.lambdaClient = client;
        this.available = avail;
    }

    public static LambdaInvoker getInstance() {
        if (instance == null) {
            synchronized (LambdaInvoker.class) {
                if (instance == null) {
                    instance = new LambdaInvoker();
                }
            }
        }
        return instance;
    }

    public boolean isAvailable() {
        return available;
    }

    /**
     * Invokes the Lambda for the given request type with the query parameters.
     *
     * @param requestType "fractals", "grayscott", or "dna"
     * @param params      query parameters as Map&lt;String,String&gt;
     * @return response body as String (base64 image or HTML)
     * @throws Exception on Lambda invocation failure
     */
    public String invoke(String requestType, Map<String, String> params) throws Exception {
        if (!available || lambdaClient == null) {
            throw new IllegalStateException("Lambda client not available");
        }

        String functionName = FUNCTION_NAMES.get(requestType);
        if (functionName == null) {
            throw new IllegalArgumentException("Unknown request type: " + requestType);
        }

        String payload = buildJsonPayload(params);

        InvokeRequest invokeRequest = new InvokeRequest()
                .withFunctionName(functionName)
                .withPayload(payload);

        InvokeResult result = lambdaClient.invoke(invokeRequest);

        if (result.getFunctionError() != null) {
            String errorPayload = result.getPayload() != null
                    ? StandardCharsets.UTF_8.decode(result.getPayload()).toString()
                    : "unknown";
            throw new RuntimeException("Lambda error: " + result.getFunctionError() + " — " + errorPayload);
        }

        String raw = StandardCharsets.UTF_8.decode(result.getPayload()).toString();
        // Lambda returns the handler's String as a JSON-encoded string (with surrounding quotes).
        // Strip them so the LB can forward the raw value (base64 image or HTML).
        return unquoteJsonString(raw);
    }

    /**
     * Strips surrounding quotes from a JSON-encoded string.
     * e.g. {@code "\"data:image/png;base64,...\""} → {@code "data:image/png;base64,..."}
     */
    private static String unquoteJsonString(String s) {
        if (s == null || s.length() < 2) return s;
        if (s.charAt(0) == '"' && s.charAt(s.length() - 1) == '"') {
            return s.substring(1, s.length() - 1);
        }
        return s;
    }

    /**
     * Builds a simple JSON object from a flat Map&lt;String,String&gt;.
     * No Jackson needed — the maps are flat and values are already strings.
     */
    private static String buildJsonPayload(Map<String, String> params) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, String> entry : params.entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(escapeJson(entry.getKey())).append("\":");
            sb.append("\"").append(escapeJson(entry.getValue())).append("\"");
            first = false;
        }
        sb.append("}");
        return sb.toString();
    }

    private static String escapeJson(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}
