## Julia Set Fractals

This project contains Julia set fractals generation functionality.

### How to build

1. Make sure your `JAVA_HOME` environment variable is set to Java 11+ distribution
2. Run `mvn clean package`

### How to run locally

To run this workload locally in CLI, execute this command:

```
java -cp target/fractals-1.0.0-SNAPSHOT-jar-with-dependencies.jar pt.ulisboa.tecnico.cnv.fractals.FractalsHandler <width> <height> <iterations> <output_image.png>
```
