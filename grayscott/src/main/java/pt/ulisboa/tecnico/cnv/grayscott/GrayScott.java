package pt.ulisboa.tecnico.cnv.grayscott;

import java.awt.image.BufferedImage;
import java.util.Locale;

public class GrayScott {
    private static final double DU = 0.16;
    private static final double DV = 0.08;
    private static final double DT = 1.0;

    private static final double EXTINCTION_EPS_PER_CELL = 1e-4;
    private static final double DISPLAY_THRESHOLD = 0.08;

    /**
     * Run the Gray-Scott simulation and return the result as a BufferedImage.
     */
    public static BufferedImage generate(int size, int maxIterations, double F, double K,
                                         boolean stopOnExtinction, String seedMode) {
        double[][] u = new double[size][size];
        double[][] v = new double[size][size];
        double[][] nextU = new double[size][size];
        double[][] nextV = new double[size][size];

        initialize(u, v, size, seedMode.toLowerCase(Locale.ROOT));

        for (int iter = 1; iter <= maxIterations; iter++) {
            double totalV = 0.0;

            for (int y = 0; y < size; y++) {
                int ym = (y == 0) ? size - 1 : y - 1;
                int yp = (y == size - 1) ? 0 : y + 1;

                for (int x = 0; x < size; x++) {
                    int xm = (x == 0) ? size - 1 : x - 1;
                    int xp = (x == size - 1) ? 0 : x + 1;

                    double U = u[y][x];
                    double V = v[y][x];

                    double lapU = u[y][xm] + u[y][xp] + u[ym][x] + u[yp][x] - 4.0 * U;
                    double lapV = v[y][xm] + v[y][xp] + v[ym][x] + v[yp][x] - 4.0 * V;

                    double reaction = U * V * V;

                    nextU[y][x] = clamp(U + (DU * lapU - reaction + F * (1.0 - U)) * DT);
                    nextV[y][x] = clamp(V + (DV * lapV + reaction - (F + K) * V) * DT);

                    totalV += nextV[y][x];
                }
            }

            double[][] tmpU = u; u = nextU; nextU = tmpU;
            double[][] tmpV = v; v = nextV; nextV = tmpV;

            if (stopOnExtinction && totalV < EXTINCTION_EPS_PER_CELL * size * size) {
                break;
            }
        }

        return renderImage(v, size);
    }

    private static BufferedImage renderImage(double[][] v, int size) {
        BufferedImage image = new BufferedImage(size, size, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                boolean highV = v[y][x] >= DISPLAY_THRESHOLD;
                int r = highV ? 255 : 0;
                int b = highV ? 0 : 255;
                image.setRGB(x, y, (r << 16) | b);
            }
        }
        return image;
    }

    private static void initialize(double[][] u, double[][] v, int size, String seedMode) {
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                u[y][x] = 1.0;
                v[y][x] = 0.0;
            }
        }

        switch (seedMode) {
            case "center":
                seedCenter(u, v, size);
                break;
            case "ring":
                seedRing(u, v, size);
                break;
            case "stripe":
                seedStripe(u, v, size);
                break;
            default:
                throw new IllegalArgumentException(
                        "Unknown seedMode: " + seedMode + ". Use center, ring, or stripe.");
        }
    }

    private static void seedCell(double[][] u, double[][] v, int x, int y, double strength) {
        double noise = pseudoNoise(x, y);
        u[y][x] = 1.0 - strength * (0.45 + 0.20 * noise);
        v[y][x] = strength * (0.18 + 0.12 * noise);
    }

    private static void seedCenter(double[][] u, double[][] v, int size) {
        int seedSize = Math.max(3, size / 30);
        int c = size / 2;

        for (int y = c - seedSize; y <= c + seedSize; y++) {
            for (int x = c - seedSize; x <= c + seedSize; x++) {
                if (inside(x, y, size)) seedCell(u, v, x, y, 1.0);
            }
        }
    }

    private static void seedRing(double[][] u, double[][] v, int size) {
        int c = size / 2;
        double radius = size * 0.28;
        double thickness = Math.max(1.5, size * 0.006);

        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                double dx = x - c;
                double dy = y - c;
                double d = Math.sqrt(dx * dx + dy * dy);

                if (Math.abs(d - radius) <= thickness) {
                    seedCell(u, v, x, y, 0.9);
                }
            }
        }
    }

    private static void seedStripe(double[][] u, double[][] v, int size) {
        int stripeWidth = Math.max(1, size / 80);
        int c = size / 2;

        for (int y = 0; y < size; y++) {
            int wiggle = (int) Math.round(Math.sin(y * 0.08) * size * 0.04);
            for (int x = c + wiggle - stripeWidth; x <= c + wiggle + stripeWidth; x++) {
                if (inside(x, y, size)) seedCell(u, v, x, y, 0.9);
            }
        }
    }

    private static boolean inside(int x, int y, int size) {
        return x >= 0 && x < size && y >= 0 && y < size;
    }

    private static double pseudoNoise(int x, int y) {
        int n = x * 374761393 + y * 668265263;
        n = (n ^ (n >>> 13)) * 1274126177;
        n = n ^ (n >>> 16);
        return (n & 0xffff) / 65535.0;
    }

    private static double clamp(double x) {
        if (x < 0.0) return 0.0;
        if (x > 1.0) return 1.0;
        return x;
    }
}
