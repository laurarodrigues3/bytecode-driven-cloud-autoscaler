## DNA Genome Matcher

This project contains DNA genome matcher functionality.

### How to build

1. Make sure your `JAVA_HOME` environment variable is set to Java 11+ distribution
2. Run `mvn clean package`

### How to run locally

To run this workload locally in CLI, execute this command:

```
java -cp target/dna-1.0.0-SNAPSHOT-jar-with-dependencies.jar pt.ulisboa.tecnico.cnv.dna.DnaHandler [seq_name1:]<seq_fasta1> [seq_name2:]<seq_fasta2> [minLength] [stopOnFirst]
```
