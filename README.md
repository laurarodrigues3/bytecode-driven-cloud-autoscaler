# bytecode-driven-cloud-autoscaler

An elastic AWS platform for compute-intensive workloads. The system uses Javassist bytecode instrumentation to count dynamic CPU instructions per request, stores those metrics in DynamoDB, and feeds them into a custom Java Load Balancer and Auto-Scaler that route and scale work based on projected cost, not wall-clock time.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Workloads](#workloads)
- [Core Systems](#core-systems)
- [Tech Stack](#tech-stack)
- [Installation](#installation)
- [Running Locally](#running-locally)
- [AWS Deployment](#aws-deployment)
- [Benchmark and Evidence Scripts](#benchmark-and-evidence-scripts)
- [Project Structure](#project-structure)

---

## Overview

Raw execution time is an unreliable scheduling signal under concurrent execution: contention, JIT warm-up, and EC2 burst credit depletion all distort it. This system replaces wall-clock time with estimated work, a composite metric derived from dynamic bytecode instruction counts (ICount) and heap allocation, extracted via a Javassist Java agent at class-load time.

Estimated work is the shared control variable across all components:

- The Javassist agent produces per-request ICount and memory metrics on EC2 workers.
- DynamoDB stores those metrics as a historical record per request.
- The ComplexityEstimator converts request parameters and history into a composite cost estimate before dispatch.
- The Load Balancer routes each request by projected worker load and Lambda eligibility.
- The Auto-Scaler scales EC2 capacity using percentage thresholds over calibrated worker capacity.

The result is a cost-aware, explainable scheduling system that packs work to enable scale-down, spreads under saturation, and reserves Lambda for small overflow requests only.

---

## Architecture

```
Client / browser / curl
        |
        v
+----------------------------------------------+
|        Load Balancer + AutoScaler  (EC2)      |
|                                              |
|  +---------------------------------------+   |
|  |         ComplexityEstimator           |   |
|  |  +-- DynamoDB history (30s cache)     |   |
|  |  +-- calibrated heuristic fallback    |   |
|  +---------------------------------------+   |
|                                              |
|  Routing decision                            |
|  +-- EC2 WorkerPool (hybrid packing/spread)  |
|  +-- AWS Lambda (small overflow / fallback)  |
+------------------+---------------------------+
                   |
       +-----------+-----------+
       |                       |
+------v------+         +------v------+
|  EC2 Worker |   ...   |  EC2 Worker |   (1-5 instances, t3.micro)
|             |         |             |
|  WebServer  |         |  WebServer  |
|  + Javassist|         |  + Javassist|
|    Agent    |         |    Agent    |
+------+------+         +------+------+
       +-----------+-----------+
                   | async batch writes
                   v
            +-------------+
            |   DynamoDB   |
            |  cnv-metrics |
            +-------------+
```

Request flow:

```
1. Client sends request to the Load Balancer
2. ComplexityEstimator computes composite cost C from parameters + DynamoDB history
3. If request is small (C <= 1x10^10) and all workers >= 80% capacity, route to Lambda
4. Otherwise, select EC2 worker via hybrid packing/spreading policy
5. Worker executes with Javassist agent active; metrics accumulate in ThreadLocal registry
6. On completion, metrics are buffered and flushed to DynamoDB in batches every 15s
7. AutoScaler reads in-flight work counters every 5s and scales EC2 pool accordingly
```

---

## Workloads

The platform serves three parameterized, CPU-intensive endpoints:

| Endpoint | Parameters | Output | Complexity profile |
|---|---|---|---|
| `GET /fractals` | `w`, `h`, `iterations` | PNG (data URI) | Linear in `w x h`; saturates at 500 iterations |
| `GET /grayscott` | `size`, `maxIterations`, `f`, `k`, `seedMode` | PNG (data URI) | ~164 instructions per cell per iteration; highly predictable |
| `GET /dna` | `seq1`, `seq2`, `minLength`, `stopOnFirst` | HTML report | Linear in `max(len(seq1), len(seq2))` |

Complexity spans several orders of magnitude: a small DNA request finishes in milliseconds, while a heavy Gray-Scott simulation can exceed 48 billion bytecode instructions.

---

## Core Systems

### 1. Bytecode Instrumentation (Javassist Agent)

The Java agent instruments only the three workload packages at class-load time, leaving the HTTP server, AWS SDK, and JDK uninstrumented.

For each target class, the agent performs three injections.

Request lifecycle hooks, injected into the `handle(HttpExchange)` method of each workload handler:
```java
MetricRegistry.startRequest(exchange.getRequestURI().toString()); // entry
MetricRegistry.stopRequest();                                      // exit (finally block)
```

ICount basic-block instruction counting: for every method of every target class, the agent uses `ControlFlow.basicBlocks()` to extract basic blocks and injects at the start of each block:
```java
MetricRegistry.incrementInstructions(N); // N = bytecode instructions in this block
```
Because the call runs every time the block is visited, loops are counted dynamically. This gives a precise, contention-free CPU work signal independent of wall-clock variability.

Method call counting as a diagnostic cross-check:
```java
MetricRegistry.incrementMethodCalls();
```

Per-request isolation uses `ThreadLocal<RequestMetrics>`. For RAM, `ThreadMXBean.getThreadAllocatedBytes()` measures the net heap delta between request entry and exit, a zero-overhead JVM-native hook requiring no bytecode injection.

---

### 2. Composite Work Metric

Scheduling uses a composite cost combining CPU and memory:

```
C = W_cpu x instructionCount + W_ram x allocatedBytes
```

Defaults: `W_cpu = W_ram = 1.0`, configurable via `-Dcnv.estwork.wcpu` and `-Dcnv.estwork.wram`. ICount dominates for CPU-bound fractals and Gray-Scott. RAM adds an independent dimension useful for DNA requests, which can allocate significant heap despite modest instruction counts.

Calibration evidence:

| Workload | CPU profile | RAM profile |
|---|---|---|
| Fractals | Linear in `w x h`; iteration count saturates at 500 (Julia-set escape) | ~33 bytes/pixel |
| Gray-Scott | Constant ~164 instr/cell/iteration across all parameter combinations | ~64 bytes/cell |
| DNA | ~123-149 instr/char of max sequence length | ~800 bytes/char |

---

### 3. Complexity Estimation

Before routing, the LB estimates each request's composite cost via two modes:

1. History mode: queries up to 50 recent DynamoDB records for the same workload type, cached locally for 30 seconds, and estimates from historical `metric / feature` ratios via linear regression.
2. Heuristic fallback: used when DynamoDB is unavailable or contains insufficient records.

Heuristic formulas:

| Workload | CPU heuristic |
|---|---|
| Fractals | `w x h x min(iterations, 500) x multiplier` (multiplier: 10 / 5 / 2 by iteration regime) |
| Gray-Scott | `size^2 x maxIterations x 164` |
| DNA | content-aware seed scan cost + `60 x (len(seq1) + len(seq2))` |

For DNA, a content-aware seed feature builds a `HashSet` of `minLength`-seeds from `seq2` and estimates match density in `seq1`, capturing the large cost difference between requests with many matches versus absent seeds without executing the full aligner.

---

### 4. Load Balancing: Hybrid Packing and Spreading

The LB selects workers using a two-regime policy:

```
Packing regime (under-capacity)
  -> Choose the most-loaded worker whose projected load stays below MAXCAP
  -> Consolidates work onto fewer VMs; leaves others idle for Auto-Scaler termination

Spreading regime (over-capacity fallback)
  -> Choose the least-loaded worker
  -> Prevents queue spikes under saturation; signals Auto-Scaler to provision more capacity
```

`MAXCAP` is calibrated to one heavy Gray-Scott request (~25s of continuous execution on a `t3.micro`).

Lambda functions act as a pressure valve, not the primary path. A request is Lambda-eligible if `C <= 1x10^10` (20% of `MAXCAP`, approximately 5s of execution). The LB routes to Lambda in two cases:

- Fast-path: request is small and all EC2 workers are at or above 80% capacity.
- Fallback: small request fails all EC2 retry attempts.

Large requests (`C > 1x10^10`) are always EC2-only.

Fault tolerance at request level: 10s connection timeout and 120s HTTP request timeout. On failure, retries up to `min(3, |pool|)` times on other workers using an exclusion list. Final fallback to Lambda for eligible requests; otherwise returns `502 Bad Gateway`.

---

### 5. Auto-Scaler

The AS runs inside the LB process, polling every 5 seconds:

```
avgCapacity (%) = 100 x sum(L(w)) / (|W| x MAXCAP)
```

| Event | Threshold | Action |
|---|---|---|
| Scale-up | avgCapacity > 80% and pool size < 5 | Launch 1 EC2 worker |
| Scale-down | avgCapacity < 20% and pool size > 1 | Drain and terminate 1 EC2 worker |

The 4x hysteresis band (80% / 20%) avoids oscillation. Each action changes pool size by exactly 1 worker. Scale-down is drain-first: the target worker is removed from the selection pool, its active request counter is polled every 2 seconds for up to 30 seconds, and the EC2 instance is terminated only when fully drained. If requests remain after the drain window, termination is deferred and the worker is re-added.

Health checks run every 15 seconds, probing each worker's `/` endpoint with a 2s timeout. A worker is evicted only after 3 consecutive failures (30-45s detection window), which filters transient GC pauses and JIT spikes. On eviction, the AS terminates the corresponding EC2 instance via the AWS SDK to prevent orphaned paid resources. If the pool drops below the minimum, a replacement worker is launched automatically.

---

### 6. Metrics Storage (DynamoDB)

Table: `cnv-metrics`

| Key | Type |
|---|---|
| Partition key | `requestType` |
| Sort key | `requestId` (timestamp + short UUID) |

Stored fields: `instructionCount`, `allocatedBytes`, `methodCallCount`, `elapsedTimeMs`, `timestamp`, and all original query parameters under `param_*`. Billing: `PAY_PER_REQUEST`.

Writes are buffered in memory and flushed as `BatchWriteItem` operations every 15 seconds in batches of up to 25 items, keeping DynamoDB off the critical request path. Workers degrade gracefully to heuristic-only estimation if DynamoDB is unavailable.

Configurable flush properties:
```bash
-Dcnv.metrics.flush.interval.seconds=15
-Dcnv.metrics.max.buffered.writes=10000
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Java 11 |
| Build | Maven 3.9+ |
| Bytecode instrumentation | Javassist |
| Cloud provider | AWS (EC2, Lambda, DynamoDB, IAM) |
| Worker instances | `t3.micro`, `eu-west-1` |
| HTTP server | Java native `HttpServer` |
| Metrics store | DynamoDB (`PAY_PER_REQUEST`) |
| AWS SDK | AWS SDK for Java v2 |
| Deployment | Bash scripts (IAM, SGs, AMI, EC2, Lambda) |

---

## Installation

Prerequisites:

- Java 11+
- Maven 3.9+
- AWS CLI configured with credentials
- AWS permissions: EC2, IAM, DynamoDB, Lambda, security groups
- WSL or Linux shell for the deployment scripts

Build:

```bash
git clone https://github.com/laurarodrigues3/bytecode-driven-cloud-autoscaler.git
cd bytecode-driven-cloud-autoscaler

mvn clean package -DskipTests
```

---

## Running Locally

Worker without instrumentation:

```bash
java -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.webserver.WebServer 8000
```

Worker with Javassist instrumentation:

```bash
java -javaagent:javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    -cp webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.webserver.WebServer 8000
```

The worker listens on `http://localhost:8000`.

Example requests:

```bash
# Fractals - returns PNG as data URI
curl "http://localhost:8000/fractals?w=400&h=400&iterations=100"

# Gray-Scott - returns PNG as data URI
curl "http://localhost:8000/grayscott?size=128&maxIterations=500&f=0.030&k=0.062&stopOnExtinction=false&seedMode=center"

# DNA - returns HTML match report
curl "http://localhost:8000/dna?seq1=seq1:ATGCATGCATGC&seq2=seq2:ATGCATGCATGC&minLength=3&stopOnFirst=false"
```

Load Balancer in local mode. Start one or more workers on different ports, then launch the LB pointing at them:

```bash
java -cp loadbalancer/target/loadbalancer-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    pt.ulisboa.tecnico.cnv.loadbalancer.LoadBalancer \
    8080 localhost:8000
```

The LB listens on `http://localhost:8080`. The root endpoint (`/`) displays the current worker pool state.

---

## AWS Deployment

All scripts live in `scripts/` and must be run from WSL/Linux in order:

```bash
cd scripts

# Optional: full teardown before a clean deployment
echo "YES" | ./99-cleanup.sh --deep

# 1. Create IAM roles and instance profiles
./01-setup-iam.sh

# 2. Create key pair, security groups, and network rules
./02-setup-network.sh

# 3. Build worker AMI (Java + JARs + systemd service)
./03-create-ami.sh

# 4. Launch initial worker
./04-launch-worker.sh

# 5. Launch Load Balancer / AutoScaler EC2
./05-launch-lb.sh $(cat .state/worker-instance-ids.txt)

# 6. Deploy Lambda workers
./06-deploy-lambdas.sh
```

The LB status page is available at `http://<LB_PUBLIC_IP>:8080/`.

Cleanup:

```bash
# Terminate EC2 instances only
./99-cleanup.sh

# Full teardown: EC2, SGs, key pair, IAM, AMI, Lambdas, DynamoDB
echo "YES" | ./99-cleanup.sh --deep
```

---

## Benchmark and Evidence Scripts

```bash
# ICount calibration matrix
bash scripts/test/_benchmark-icount.sh

# Extended workload calibration
bash scripts/test/_benchmark-extended.sh

# DNA seed feature benchmark
python scripts/test/_benchmark-dna-features.py

# Smoke tests and scale/resilience validation
bash scripts/test/_smoke-test.sh
bash scripts/test/_test-scale.sh
bash scripts/test/_test-resilience.sh
```

---

## Project Structure

```
.
+-- pom.xml
+-- fractals/             # Julia-set fractal generator
+-- grayscott/            # Gray-Scott reaction-diffusion simulation
+-- dna/                  # FASTA/DNA sequence aligner
+-- javassist/            # Bytecode instrumentation Java agent
+-- webserver/            # HTTP worker server
+-- loadbalancer/         # Load Balancer, AutoScaler, ComplexityEstimator
+-- scripts/
|   +-- 01-setup-iam.sh
|   +-- 02-setup-network.sh
|   +-- 03-create-ami.sh
|   +-- 04-launch-worker.sh
|   +-- 05-launch-lb.sh
|   +-- 06-deploy-lambdas.sh
|   +-- 99-cleanup.sh
|   +-- test/             # Calibration and validation scripts
+-- pagina.html           # Static HTML client for manual workload testing
```
