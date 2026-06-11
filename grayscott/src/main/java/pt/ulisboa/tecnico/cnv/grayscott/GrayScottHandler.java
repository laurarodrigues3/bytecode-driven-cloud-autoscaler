package pt.ulisboa.tecnico.cnv.grayscott;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.net.URI;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

public class GrayScottHandler implements HttpHandler, RequestHandler<Map<String, String>, String> {

    /**
     * Entrypoint for the workload.
     */
    private String handleWorkload(int size, int maxIterations, double F, double K,
                                   boolean stopOnExtinction, String seedMode) {
        BufferedImage image = GrayScott.generate(size, maxIterations, F, K, stopOnExtinction, seedMode);

        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            ImageIO.write(image, "png", baos);
            String base64Image = Base64.getEncoder().encodeToString(baos.toByteArray());
            return String.format("data:image/png;base64,%s", base64Image);
        } catch (IOException e) {
            e.printStackTrace();
            return "{ \"error\":\"" + e.getMessage() + "\"}";
        }
    }

    /**
     * Entrypoint for HTTP requests.
     */
    @Override
    public void handle(HttpExchange he) throws IOException {
        // Handling CORS.
        he.getResponseHeaders().add("Access-Control-Allow-Origin", "*");

        if ("OPTIONS".equalsIgnoreCase(he.getRequestMethod())) {
            he.getResponseHeaders().add("Access-Control-Allow-Methods", "GET, OPTIONS");
            he.getResponseHeaders().add("Access-Control-Allow-Headers", "Content-Type,Authorization");
            he.sendResponseHeaders(204, -1);
            return;
        }

        // Parse request.
        URI requestedUri = he.getRequestURI();
        String query = requestedUri.getRawQuery();
        Map<String, String> parameters = queryToMap(query);

        try {
            int size = Integer.parseInt(parameters.getOrDefault("size", "256"));
            int maxIterations = Integer.parseInt(parameters.getOrDefault("maxIterations", "5000"));
            double F = Double.parseDouble(parameters.getOrDefault("f", "0.030"));
            double K = Double.parseDouble(parameters.getOrDefault("k", "0.062"));
            boolean stopOnExtinction = Boolean.parseBoolean(parameters.getOrDefault("stopOnExtinction", "false"));
            String seedMode = parameters.getOrDefault("seedMode", "center");

            String response = handleWorkload(size, maxIterations, F, K, stopOnExtinction, seedMode);

            he.sendResponseHeaders(200, response.length());
            OutputStream os = he.getResponseBody();
            os.write(response.getBytes());
            os.close();
        } catch (NumberFormatException e) {
            e.printStackTrace();
            String errorResponse = "{ \"error\":\"Invalid parameter format.\"}";
            he.sendResponseHeaders(400, errorResponse.length());
            OutputStream os = he.getResponseBody();
            os.write(errorResponse.getBytes());
            os.close();
        }
    }

    /**
     * Entrypoint for AWS Lambda.
     */
    @Override
    public String handleRequest(Map<String, String> event, Context context) {
        try {
            int size = Integer.parseInt(event.getOrDefault("size", "256"));
            int maxIterations = Integer.parseInt(event.getOrDefault("maxIterations", "5000"));
            double F = Double.parseDouble(event.getOrDefault("f", "0.030"));
            double K = Double.parseDouble(event.getOrDefault("k", "0.062"));
            boolean stopOnExtinction = Boolean.parseBoolean(event.getOrDefault("stopOnExtinction", "false"));
            String seedMode = event.getOrDefault("seedMode", "center");

            return handleWorkload(size, maxIterations, F, K, stopOnExtinction, seedMode);
        } catch (NumberFormatException e) {
            return "{ \"error\":\"Invalid parameter format.\"}";
        }
    }

    /**
     * For debugging use - to run from CLI.
     */
    public static void main(String[] args) {
        if (args.length < 6) {
            System.err.println("Usage: java pt.ulisboa.tecnico.cnv.grayscott.GrayScottHandler <size> <maxIterations> <feedF> <killK> <stopOnExtinction:true|false> <seedMode:center|ring|stripe> [output.png]");
            return;
        }

        try {
            int size = Integer.parseInt(args[0]);
            int maxIterations = Integer.parseInt(args[1]);
            double F = Double.parseDouble(args[2]);
            double K = Double.parseDouble(args[3]);
            boolean stopOnExtinction = Boolean.parseBoolean(args[4]);
            String seedMode = args[5];
            String outputPath = args.length >= 7 ? args[6] : "output.png";

            BufferedImage image = GrayScott.generate(size, maxIterations, F, K, stopOnExtinction, seedMode);

            File outputFile = new File(outputPath);
            ImageIO.write(image, "png", outputFile);
            System.out.println("GrayScott image saved to: " + outputFile.getAbsolutePath());

        } catch (NumberFormatException e) {
            System.err.println("Error: size and maxIterations must be integers; feedF and killK must be doubles.");
            System.exit(1);
        } catch (IOException e) {
            System.err.println("Failed to write output image: " + e.getMessage());
            System.exit(1);
        }
    }

    /**
     * Parse query string into a map.
     */
    private Map<String, String> queryToMap(String query) {
        if (query == null) {
            return new HashMap<>();
        }
        Map<String, String> result = new HashMap<>();
        for (String param : query.split("&")) {
            String[] entry = param.split("=");
            if (entry.length > 1) {
                result.put(entry[0], entry[1]);
            } else {
                result.put(entry[0], "");
            }
        }
        return result;
    }
}
