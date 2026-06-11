# Nature@Cloud

> **CNV 2025/26** — Cloud Computing and Virtualization @ IST
>
> Custom AWS elastic platform for Nature@Cloud workloads: Julia fractals, Gray-Scott reaction-diffusion, and DNA matching. The system uses Javassist bytecode instrumentation, DynamoDB-backed metrics, complexity-aware load balancing, Lambda fallback/overflow, and a custom EC2 AutoScaler.

## Current Architecture

```text
Client / browser / curl
        │
        ▼
Load Balancer + AutoScaler on EC2, port 8080
        │
        ├── ComplexityEstimator
        │      ├── DynamoDB history cache, 30s TTL
        │      └── calibrated heuristic fallback
        │
        ├── EC2 WorkerPool, port 8000
        │      ├── Java WebServer + CachedThreadPool
        │      ├── Javassist javaagent
        │      └── buffered metric writes to DynamoDB
        │
        ├── AWS Lambda workers for small overflow/fallback requests
        │      ├── cnv-fractals
        │      ├── cnv-grayscott
        │      └── cnv-dna
        │
        └── AWS EC2 API for worker launch/termination

DynamoDB MSS: cnv-metrics
```

| Component | Description |
|---|---|
| `webserver` | HTTP server exposing `/fractals`, `/grayscott`, `/dna`, and `/` health endpoint |
| `fractals` | Julia-set fractal image generation |
| `grayscott` | Gray-Scott reaction-diffusion simulation |
| `dna` | FASTA/DNA sequence matcher with HTML output |
| `javassist` | Java agent collecting `instructionCount`, `allocatedBytes`, `methodCallCount`, and `elapsedTimeMs` |
| `loadbalancer` | Custom Java LB + AutoScaler + ComplexityEstimator + LambdaInvoker |
| `scripts` | AWS provisioning, Lambda deployment, benchmark, and cleanup scripts |
| `docs` | Calibration evidence, runbooks, design notes, and validation reports |
| `report` | LaTeX report sources |

## Prerequisites

- Java 11+
- Maven 3.9+
- AWS CLI configured with credentials, for cloud deployment
- AWS permissions for EC2, IAM, DynamoDB, Lambda, and security groups
- WSL/Linux shell for the deployment scripts

## Quick Start: Local Worker

Build all modules:

```bash
mvn clean package -DskipTests
```

Run the webserver without instrumentation:

```bash
java -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.webserver.WebServer 8000
```

Run the webserver with Javassist instrumentation:

```bash
java -javaagent:javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.webserver.WebServer 8000
```

The worker listens on `http://localhost:8000`.

Example requests:

```bash
# Fractals — returns a data:image/png;base64,... string
curl "http://localhost:8000/fractals?w=400&h=400&iterations=100"

# Gray-Scott — returns a data:image/png;base64,... string
curl "http://localhost:8000/grayscott?size=128&maxIterations=500&f=0.030&k=0.062&stopOnExtinction=false&seedMode=center"

# DNA — returns an HTML report
curl "http://localhost:8000/dna?seq1=seq1:ATGCATGCATGC&seq2=seq2:ATGCATGCATGC&minLength=3&stopOnFirst=false"
```

## Quick Start: Local Load Balancer

Start one or more local workers on different ports, then launch the LB with their addresses:

```bash
java -cp loadbalancer/target/loadbalancer-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.loadbalancer.LoadBalancer \
    8080 localhost:8000
```

The LB listens on `http://localhost:8080` and forwards only workload paths. The root endpoint shows the current worker pool.

## AWS Deployment

All scripts live in `scripts/` and should be run from WSL/Linux. A typical deployment is:

```bash
cd scripts

# Optional: full teardown before a clean deployment
echo "YES" | ./99-cleanup.sh --deep

# 1. Create IAM roles and instance profiles
./01-setup-iam.sh

# 2. Create key pair, security groups, and network rules
./02-setup-network.sh

# 3. Build worker AMI with Java + JARs + systemd service
./03-create-ami.sh

# 4. Launch initial worker
./04-launch-worker.sh

# 5. Launch Load Balancer / AutoScaler EC2
./05-launch-lb.sh $(cat .state/worker-instance-ids.txt)

# 6. Deploy/update Lambda workers
./06-deploy-lambdas.sh
```

After deployment, the LB status page is available at:

```text
http://<LB_PUBLIC_IP>:8080/
```

### Cleanup

```bash
# Terminate project EC2 instances only
./99-cleanup.sh

# Full teardown: EC2, SGs, key pair, IAM roles, AMI, Lambdas, DynamoDB, etc.
echo "YES" | ./99-cleanup.sh --deep
```

## How It Works

### Instrumentation and Metrics

EC2 workers run with the Javassist Java agent. The agent instruments only workload packages:

- `pt.ulisboa.tecnico.cnv.fractals`
- `pt.ulisboa.tecnico.cnv.grayscott`
- `pt.ulisboa.tecnico.cnv.dna`

The primary CPU metric is `instructionCount`. The agent uses real basic blocks from Javassist `ControlFlow.basicBlocks()` and injects:

```java
MetricRegistry.incrementInstructions(N)
```

where `N` is the number of bytecode instructions in that block. Since the injected call runs every time the block is visited, loops are counted dynamically.

Collected metrics:

| Metric | Purpose |
|---|---|
| `instructionCount` | Primary CPU/work signal |
| `allocatedBytes` | Memory pressure via `ThreadMXBean.getThreadAllocatedBytes()` |
| `methodCallCount` | Diagnostic/cross-check metric |
| `elapsedTimeMs` | Validation/correlation only, not primary scheduling signal |

Per-request isolation is done with `ThreadLocal<RequestMetrics>`.

### Metrics Storage System: DynamoDB

DynamoDB table:

```text
cnv-metrics
```

Primary key:

| Key | Value |
|---|---|
| Partition key | `requestType` |
| Sort key | `requestId` = timestamp + short UUID |

Stored fields:

| Field | Type | Description |
|---|---|---|
| `requestId` | String | Unique item id |
| `requestType` | String | `fractals`, `grayscott`, or `dna` |
| `instructionCount` | Number | Dynamic bytecode instructions |
| `allocatedBytes` | Number | Bytes allocated by the request thread |
| `methodCallCount` | Number | Method invocations |
| `elapsedTimeMs` | Number | Wall-clock duration |
| `timestamp` | Number | Completion timestamp |
| `param_*` | String | Original request parameters |

Writes are not sent one-by-one. Completed-request metrics are buffered in memory and flushed every 15 seconds using DynamoDB `BatchWriteItem` batches of up to 25 items.

Configurable properties:

```bash
-Dcnv.metrics.flush.interval.seconds=15
-Dcnv.metrics.max.buffered.writes=10000
```

This keeps request processing off the DynamoDB critical path and reduces SDK/HTTP overhead, while preserving one historical item per request for the estimator.

### Complexity Estimation

The LB estimates each request before routing it.

1. **History mode:** query up to the 50 most recent DynamoDB records for the same `requestType`, cached locally for 30 seconds, and estimate from historical `metric / feature` ratios.
2. **Heuristic fallback:** used when DynamoDB is unavailable, empty, or contains no valid records.

Heuristic features:

| Workload | CPU heuristic | RAM heuristic |
|---|---|---|
| Fractals | `w × h × min(iterations, 500) × multiplier`, where multiplier is `10`, `5`, or `2` by iteration regime | `w × h × 33` |
| Gray-Scott | `size² × maxIterations × 164` | `size² × 64` |
| DNA | `17 × seedPresenceScan + 60 × (len(seq1)+len(seq2))` | `52 × seedPresenceScan + 480 × (len(seq1)+len(seq2))` |

For DNA, `seedPresenceScan` is a lightweight content-aware feature. The estimator builds a `HashSet` of `minLength`-seeds from `seq2`; for each seed in `seq1`, it adds a small cost if present in `seq2`, otherwise a full-scan cost. This captures the large difference between same-size DNA requests with many matches and requests with absent seeds, without executing the full matcher.

Composite cost:

```text
compositeCost = W_CPU × instructionCount + W_RAM × allocatedBytes
```

Defaults:

```bash
-Dcnv.estwork.wcpu=1.0
-Dcnv.estwork.wram=1.0
```

### Load Balancing

The custom LB is the only public entry point. It estimates request cost, converts the estimate to seconds using calibrated `t3.micro` throughput, then decides where to send the request.

Constants:

| Parameter | Default | Meaning |
|---|---:|---|
| `LAMBDA_MAX_SECONDS` | `5.0` | Maximum estimated seconds for Lambda eligibility |
| `WORKER_LOAD_THRESHOLD` | `0.80` | Worker considered busy for Lambda fast-path |
| `MAX_CAPACITY` | `5×10¹⁰` | 100% worker capacity / 25s calibrated work |
| `WORKER_THROUGHPUT_INSTR_PER_MS` | `2.0×10⁶` | Calibrated `t3.micro` throughput |

Configurable Lambda properties:

```bash
-Dcnv.lambda.maxseconds=5.0
-Dcnv.lambda.loadthreshold=0.80
```

Routing policy:

1. Estimate cost for `requestType + parameters`.
2. If the request is Lambda-eligible (`estimatedSeconds ≤ 5`) and all EC2 workers are above 80% capacity, invoke Lambda directly.
3. Otherwise, try EC2 first.
4. EC2 worker selection uses **hybrid packing + spreading fallback**:
   - choose the most-loaded worker that remains below `MAX_CAPACITY` after adding the request;
   - if none fit, choose the least-loaded worker.
5. On transport failure/timeout, retry on a different worker, up to 3 EC2 attempts.
6. If all EC2 attempts fail and the request is Lambda-eligible, fallback to Lambda.
7. Large requests (`estimatedSeconds > 5`) are EC2-only and are not sent to Lambda.

Note: current retries are triggered by transport failures/timeouts. Application-level HTTP status codes returned by a worker are forwarded to the client.

### AutoScaler

The AutoScaler runs inside the LB process. It discovers existing workers by EC2 tags and can launch or terminate workers using the EC2 SDK.

Scaling metric:

```text
avgCapacityPercent = 100 × totalEstimatedWork / (numWorkers × MAX_CAPACITY)
```

Defaults:

| Parameter | Value | Meaning |
|---|---:|---|
| `MIN_WORKERS` | `1` | Minimum worker pool size |
| `MAX_WORKERS` | `5` | Cost/quota cap |
| Check interval | `5s` | Scaling loop interval |
| Cooldown | `60s` | Minimum time between real scaling actions |
| Scale-up | `80%` average capacity | About 20s of work per worker |
| Scale-down | `20%` average capacity | About 5s of work per worker |
| Drain wait | `15 × 2s = 30s` | Wait before terminating on scale-down |

Configurable properties:

```bash
-Dcnv.autoscaler.scaleup.percent=80.0
-Dcnv.autoscaler.scaledown.percent=20.0
```

Scale-down is drain-first: the chosen worker is removed from selection, the AS waits for active requests to finish, and the EC2 instance is terminated only when the worker is drained. If active requests remain after the drain window, termination is deferred and the worker is re-added.

### Fault Tolerance

Fault tolerance is layered:

- **Request level:** forwarding failures, connection errors, and timeouts cause retry on another EC2 worker, excluding workers already tried for that request.
- **Lambda fallback:** if EC2 retries fail, only Lambda-eligible requests are sent to Lambda. Large requests remain EC2-only.
- **Worker health checks:** every 15 seconds, the pool probes each worker's `/` endpoint with a short timeout.
- **Eviction:** a worker is removed only after 3 consecutive failed health checks, avoiding false positives during VM startup or transient pauses.
- **EC2 cleanup:** when an AutoScaler-managed worker is evicted, the AutoScaler terminates the corresponding EC2 instance to avoid orphan resources.
- **Graceful degradation:** no DynamoDB means heuristic estimation; no Lambda means EC2-only routing; no AWS config means local/log-only scaling mode.

## Benchmark and Evidence Scripts

Useful local scripts:

```bash
# Original ICount calibration matrix
bash scripts/test/_benchmark-icount.sh

# Extended workload calibration
bash scripts/test/_benchmark-extended.sh

# DNA-specific feature benchmark
python scripts/test/_benchmark-dna-features.py

# Local smoke tests / AWS helpers
bash scripts/test/_smoke-test.sh
bash scripts/test/_test-scale.sh
bash scripts/test/_test-resilience.sh
```

Generated evidence is stored under `docs/`, including:

- `docs/evidence-2026-05-21-calibration/`
- `docs/evidence-dna-feature-benchmark/`
- `docs/test-report-aws-2026-05-22.md`

## Project Structure

```text
.
├── pom.xml
├── fractals/
├── grayscott/
├── dna/
├── javassist/
├── webserver/
├── loadbalancer/
├── scripts/
│   ├── aws-config.sh
│   ├── 01-setup-iam.sh
│   ├── 02-setup-network.sh
│   ├── 03-create-ami.sh
│   ├── 04-launch-worker.sh
│   ├── 05-launch-lb.sh
│   ├── 06-deploy-lambdas.sh
│   ├── 99-cleanup.sh
│   └── test/
├── docs/
├── report/
└── REPORT_SUPPORT/
```

## Current Status

Implemented and validated locally/build-wise:

- EC2 worker webserver for all three workloads
- Javassist ICount instrumentation
- `allocatedBytes` memory metric
- DynamoDB MSS with buffered batch writes
- history-based + heuristic `ComplexityEstimator`
- content-aware DNA seed feature
- custom Java Load Balancer
- Lambda fast-path and fallback for small requests
- custom Java AutoScaler with 80%/20% capacity thresholds
- worker health checks and EC2 eviction cleanup
- AWS deployment and cleanup scripts
- final report source in `report/final-report.tex`

## Group

CNV Group 35 — 2025/26
