package pt.ulisboa.tecnico.cnv.dna;

import java.io.IOException;
import java.io.OutputStream;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import static pt.ulisboa.tecnico.cnv.dna.Dna.runDna;

public class DnaHandler implements HttpHandler, RequestHandler<Map<String, String>, String> {

    /**
     * Entrypoint for the workload.
     */
    private String handleWorkload(String seq1Param, String seq2Param, int minLength, boolean stopOnFirst) {
        try {
            String[] seq1 = Dna.parseDnaParam(seq1Param);
            String[] seq2 = Dna.parseDnaParam(seq2Param);
            String seq1Parsed = Dna.parseFastaContent(seq1[1]);
            String seq2Parsed = Dna.parseFastaContent(seq2[1]);
            return Dna.runDna(seq1Parsed, seq2Parsed, minLength, seq1[0], seq2[0], stopOnFirst);
        } catch (NumberFormatException | IOException e) {
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

        URI requestedUri = he.getRequestURI();
        String query = requestedUri.getRawQuery();
        Map<String, String> parameters = queryToMap(query);

        try {
            String seq1Param = URLDecoder.decode(parameters.getOrDefault("seq1", "seq1:ATGC"), StandardCharsets.UTF_8);
            String seq2Param = URLDecoder.decode(parameters.getOrDefault("seq2", "seq2:ATGC"), StandardCharsets.UTF_8);

            String minLengthParam = parameters.getOrDefault("minLength", "1");
            String stopOnFirstParam = parameters.getOrDefault("stopOnFirst", "false");
            int minLength = Integer.parseInt(minLengthParam);
            boolean stopOnFirst = Boolean.parseBoolean(stopOnFirstParam);

            String response = handleWorkload(seq1Param, seq2Param, minLength, stopOnFirst);

            he.sendResponseHeaders(200, response.getBytes().length);
            OutputStream os = he.getResponseBody();
            os.write(response.getBytes());
            os.close();

        } catch (NumberFormatException e) {
            e.printStackTrace();
            String errorResponse = "{ \" error\":\" Invalid minLength parameter: " + e.getMessage() + "\"}";
            he.sendResponseHeaders(400, errorResponse.getBytes().length);
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
            String seq1Param = event.getOrDefault("seq1", "seq1:ATGC");
            String seq2Param = event.getOrDefault("seq2", "seq2:ATGC");
            String minLengthParam = event.getOrDefault("minLength", "1");
            boolean stopOnFirst = Boolean.parseBoolean(event.getOrDefault("stopOnFirst", "false"));

            int minLength = Integer.parseInt(minLengthParam);
            return handleWorkload(seq1Param, seq2Param, minLength, stopOnFirst);
        } catch (NumberFormatException e) {
            return "{ \" error\":\" Invalid minLength parameter: " + e.getMessage() + "\"}";
        }
    }

    /**
     * For debugging use - to run from CLI.
     */
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("Usage: java -cp pt.ulisboa.tecnico.cnv.dna.DnaHandler <[name1:]seq_fasta1> <[name2:]seq_fasta2> [minLength] [stopOnFirst]");
            return;
        }
        String[] seq1 = args.length > 0 ? Dna.parseDnaParam(args[0]) : Dna.parseDnaParam("seq1:ATGC");
        String[] seq2 = args.length > 1 ? Dna.parseDnaParam(args[1]) : Dna.parseDnaParam("seq2:ATGC");
        int minLength = args.length > 2 ? Integer.parseInt(args[2]) : 1;
        boolean stopOnFirst = args.length > 3 ? Boolean.parseBoolean(args[3]) : false;

        String seq1Parsed = Dna.parseFastaContent(seq1[1]);
        String seq2Parsed = Dna.parseFastaContent(seq2[1]);

        String html = runDna(seq1Parsed, seq2Parsed, minLength, seq1[0], seq2[0], stopOnFirst);
        Path outputPath = Paths.get("dna-match-result.html");
        Files.writeString(outputPath, html);
        System.out.println("Dna result successfully saved to: " + outputPath.toAbsolutePath());
    }

    /**
     * Parse query string into a map.
     */
    public Map<String, String> queryToMap(String query) {
        if (query == null) {
            return null;
        }

        Map<String, String> result = new HashMap<>();
        for (String param : query.split("&")) {
            String[] entry = param.split("=", 2);
            if (entry.length > 1) {
                result.put(entry[0], entry[1]);
            } else {
                result.put(entry[0], "");
            }
        }
        return result;
    }
}
