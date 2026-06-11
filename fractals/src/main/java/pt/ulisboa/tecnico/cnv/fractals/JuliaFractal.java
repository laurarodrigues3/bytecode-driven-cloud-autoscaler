package pt.ulisboa.tecnico.cnv.fractals;

import java.awt.image.BufferedImage;

public class JuliaFractal {

    private static final double cRe = -0.4;
    private static final double cIm = 0.6;
    private static final double zoom = 1.0;

    public static BufferedImage generate(int width, int height, int maxIterations) {
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);

        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {

                double zx = 1.5 * (x - width / 2.0) / (0.5 * zoom * width);
                double zy = (y - height / 2.0) / (0.5 * zoom * height);
                int i = maxIterations;

                while (zx * zx + zy * zy < 4 && i > 0) {
                    double tmp = zx * zx - zy * zy + cRe;
                    zy = 2.0 * zx * zy + cIm;
                    zx = tmp;
                    i--;
                }

                // Green-scale coloring.
                int color = 0;
                if (i > 0) {
                    // Creating a gradient based on how fast the point escaped.
                    int intensity = (int) ((maxIterations - i) * 255.0 / maxIterations);
                    color = (intensity << 8); // Shift to green channel.
                }

                image.setRGB(x, y, color);
            }
        }

        return image;
    }
}
