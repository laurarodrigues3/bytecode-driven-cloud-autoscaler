package pt.ulisboa.tecnico.cnv.loadbalancer;

/**
 * Configuração centralizada relativa à AWS, lida de system properties
 * (preferíveis a env vars para fins de demonstração e do enunciado).
 *
 * Exemplo de invocação:
 *   java -Daws.region=eu-west-1 \
 *        -Dcnv.ami.id=ami-0xxx \
 *        -Dcnv.worker.sg.id=sg-xxxx \
 *        -Dcnv.keypair.name=cnv-keypair \
 *        -Dcnv.worker.instance.profile=CNV-Worker-Role \
 *        -cp loadbalancer-...jar pt.ulisboa.tecnico.cnv.loadbalancer.LoadBalancer 8080
 *
 * Todos os valores têm defaults sensatos para que o sistema arranque
 * em modo "local-only" (sem chamadas AWS) caso falte configuração.
 */
public final class AwsConfig {

    public static final String REGION =
            System.getProperty("aws.region", "eu-west-1");

    public static final String WORKER_AMI_ID =
            System.getProperty("cnv.ami.id", "");

    public static final String WORKER_SG_ID =
            System.getProperty("cnv.worker.sg.id", "");

    public static final String KEYPAIR_NAME =
            System.getProperty("cnv.keypair.name", "cnv-keypair");

    public static final String WORKER_INSTANCE_PROFILE =
            System.getProperty("cnv.worker.instance.profile", "CNV-Worker-Role");

    public static final String INSTANCE_TYPE =
            System.getProperty("cnv.instance.type", "t3.micro");

    public static final int WORKER_PORT =
            Integer.parseInt(System.getProperty("cnv.worker.port", "8000"));

    /**
     * Indica se a configuração mínima necessária para o AutoScaler
     * fazer chamadas reais a EC2 está disponível.
     */
    public static boolean isAwsScalingEnabled() {
        return !WORKER_AMI_ID.isEmpty() && !WORKER_SG_ID.isEmpty();
    }

    public static String summary() {
        return String.format(
                "AwsConfig{region=%s, ami=%s, sg=%s, keyPair=%s, instanceProfile=%s, type=%s, port=%d, scalingEnabled=%s}",
                REGION,
                WORKER_AMI_ID.isEmpty() ? "<unset>" : WORKER_AMI_ID,
                WORKER_SG_ID.isEmpty() ? "<unset>" : WORKER_SG_ID,
                KEYPAIR_NAME, WORKER_INSTANCE_PROFILE, INSTANCE_TYPE, WORKER_PORT,
                isAwsScalingEnabled());
    }

    private AwsConfig() {}
}
