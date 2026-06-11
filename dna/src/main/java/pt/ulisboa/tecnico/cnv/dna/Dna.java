package pt.ulisboa.tecnico.cnv.dna;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;


public class Dna {

    private static class Match {

        final int seq1Start;
        final int seq1End;
        final int seq2Start;
        final int seq2End;

        Match(int seq1Start, int seq1End, int seq2Start, int seq2End) {
            this.seq1Start = seq1Start;
            this.seq1End = seq1End;
            this.seq2Start = seq2Start;
            this.seq2End = seq2End;
        }
    }


    /**
     * Parse <name>:<fasta_content> to [name, fasta_content].
     */
    protected static String[] parseDnaParam(String param) {
        int colon = param.indexOf(':');
        if (colon < 0) {
            return new String[]{"seq", param};
        }
        return new String[]{param.substring(0, colon), param.substring(colon + 1)};
    }

    /**
     * Read fasta file from resources folder.
     */
    protected static String readFastaFile(String filename) throws IOException {
        try (InputStream is = Dna.class.getClassLoader().getResourceAsStream(filename)) {
            if (is == null) {
                throw new IOException("Fasta file not found: " + filename);
            }
            return new String(is.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    protected static String parseFastaContent(String fasta) {
        StringBuilder seq = new StringBuilder();
        for (String line : fasta.split("\n")) {
            String trimmed = line.trim();
            // Ignoring metadata.
            if (!trimmed.isEmpty() && !trimmed.startsWith(">") && !trimmed.startsWith(";")) {
                seq.append(trimmed.toUpperCase());
            }
        }
        return seq.toString();
    }

    protected static String runDna(String seq1, String seq2, int minLength, String seq1Name, String seq2Name, boolean stopOnFirst) throws NumberFormatException, IOException {
        List<Match> results = runDnaSequenceMatcher(seq1, seq2, minLength, stopOnFirst);

        boolean[] seq1Matched = new boolean[seq1.length()];
        boolean[] seq2Matched = new boolean[seq2.length()];
        for (Match r : results) {
            for (int i = r.seq1Start; i < r.seq1End; i++) seq1Matched[i] = true;
            for (int i = r.seq2Start; i < r.seq2End; i++) seq2Matched[i] = true;
        }

        return DnaHtmlRenderer.render(seq1, seq2, seq1Name, seq2Name, minLength, stopOnFirst, results.size(), seq1Matched, seq2Matched);
    }

    private static List<Match> runDnaSequenceMatcher(String seq1, String seq2, int minLength, boolean stopOnFirst) {
        List<Match> results = new ArrayList<>();
        int seq2StartIndex = 0;

        for (int i = 0; i <= seq1.length() - minLength; i++) {
            String seed = seq1.substring(i, i + minLength);
            int j = findSeed(seq2, seed, seq2StartIndex, minLength);
            if (j < 0) continue;

            int[] ends = extendRight(seq1, seq2, i + minLength, j + minLength);
            results.add(new Match(i, ends[0], j, ends[1]));

            if (stopOnFirst) return results;

            seq2StartIndex = ends[1];
            i = ends[0] - 1;
        }

        return results;
    }

    private static int findSeed(String seq2, String seed, int seq2StartIndex, int minLength) {
        for (int j = seq2StartIndex; j <= seq2.length() - minLength; j++) {
            if (seed.equals(seq2.substring(j, j + minLength))) {
                return j;
            }
        }
        return -1;
    }

    private static int[] extendRight(String seq1, String seq2, int end1, int end2) {
        while (end1 < seq1.length() && end2 < seq2.length() && seq1.charAt(end1) == seq2.charAt(end2)) {
            end1++;
            end2++;
        }
        return new int[]{end1, end2};
    }
}
