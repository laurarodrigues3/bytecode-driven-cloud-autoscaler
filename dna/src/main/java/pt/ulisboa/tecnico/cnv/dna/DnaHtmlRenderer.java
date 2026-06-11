package pt.ulisboa.tecnico.cnv.dna;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

class DnaHtmlRenderer {

    private static final String COLOR_MATCH_A = "#f4c20d";
    private static final String COLOR_MATCH_C = "#4285f4";
    private static final String COLOR_MATCH_G = "#34a853";
    private static final String COLOR_MATCH_T = "#ea4335";
    private static final String COLOR_UNALIGNED = "#d9d9d9";
    private static final int MAX_DISPLAY_LENGTH = 1000;

    static String render(String seq1, String seq2, String seq1Name, String seq2Name,
                         int minLength, boolean stopOnFirst, int matchCount,
                         boolean[] seq1Aligned, boolean[] seq2Aligned) throws IOException {
        StringBuilder summaryRows = new StringBuilder();
        summaryRows.append(row("minimum length", String.valueOf(minLength)));
        summaryRows.append(row("stop on first", String.valueOf(stopOnFirst)));
        summaryRows.append(row("matches found", String.valueOf(matchCount)));

        StringBuilder matchBlock = new StringBuilder();
        matchBlock.append("<div class=\"match-block\">");
        appendSequenceRow(matchBlock, seq1Name, seq1, seq1Aligned, 80);
        appendSequenceRow(matchBlock, seq2Name, seq2, seq2Aligned, 80);
        matchBlock.append("</div>");

        String template;
        try (InputStream stream = DnaHtmlRenderer.class.getClassLoader().getResourceAsStream("dna-result-template.html")) {
            template = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }

        return template
                .replace("{{SUMMARY_ROWS}}", summaryRows.toString())
                .replace("{{MATCH_BLOCK}}", matchBlock.toString());
    }

    private static String row(String label, String value) {
        return "<tr><td>" + label + "</td><td>" + value + "</td></tr>";
    }

    private static void appendSequenceRow(StringBuilder html, String label, String sequence, boolean[] aligned, int chunkSize) {
        html.append("<div class=\"sequence-label\">").append(label).append("</div>");
        int displayLength = Math.min(sequence.length(), MAX_DISPLAY_LENGTH);
        for (int start = 0; start < displayLength; start += chunkSize) {
            int end = Math.min(start + chunkSize, displayLength);
            html.append("<div class=\"sequence-row chunk\">");
            for (int i = start; i < end; i++) {
                char base = sequence.charAt(i);
                String color = aligned[i] ? computeBaseColor(base) : COLOR_UNALIGNED;
                html.append("<span class=\"base\" style=\"background:")
                        .append(color)
                        .append("\">")
                        .append(base)
                        .append("</span>");
            }
            html.append("</div>");
        }
        if (sequence.length() > MAX_DISPLAY_LENGTH) {
            html.append("<div class=\"sequence-row\">... (hiding last ")
                    .append(sequence.length() - MAX_DISPLAY_LENGTH)
                    .append(" bases)</div>");
        }
    }

    private static String computeBaseColor(char base) {
        char upper = Character.toUpperCase(base);
        if (upper == 'A') return COLOR_MATCH_A;
        if (upper == 'C') return COLOR_MATCH_C;
        if (upper == 'G') return COLOR_MATCH_G;
        if (upper == 'T') return COLOR_MATCH_T;
        return COLOR_MATCH_A;
    }
}
