## Gray-Scott Reaction-Diffusion

This project contains Gray-Scott reaction-diffusion pattern generation functionality.

### How to build

1. Make sure your `JAVA_HOME` environment variable is set to Java 11+ distribution

2. Run `mvn clean package`

### How to run locally

To run this workload locally in CLI, execute this command:

```
java -cp target/grayscott-1.0.0-SNAPSHOT-jar-with-dependencies.jar pt.ulisboa.tecnico.cnv.grayscott.GrayScottHandler <size> <maxIterations> <feedF> <killK> <stopOnExtinction:true|false> <seedMode:center|ring|stripe> [output_image.png]
```
