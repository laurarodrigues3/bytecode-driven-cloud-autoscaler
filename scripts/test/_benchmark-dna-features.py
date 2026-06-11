#!/usr/bin/env python3
"""
DNA feature benchmark for Nature@Cloud.

Runs a local instrumented worker, sends a curated DNA request matrix, captures
MetricRegistry lines, and evaluates simple/multiple linear models for estimating
DNA instructionCount and allocatedBytes.
"""

from __future__ import annotations

import csv
import math
import os
import random
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PORT = 8010
LOG = ROOT / "docs" / "evidence-dna-feature-benchmark" / "dna-feature-worker.log"
CSV_OUT = ROOT / "docs" / "evidence-dna-feature-benchmark" / "dna-feature-benchmark.csv"
SUMMARY_OUT = (
    ROOT / "docs" / "evidence-dna-feature-benchmark" / "dna-feature-summary.txt"
)
AGENT_JAR = (
    ROOT
    / "javassist"
    / "target"
    / "javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
)
WS_JAR = (
    ROOT / "webserver" / "target" / "webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
)

METRICS_RE = re.compile(
    r"^\[Metrics\] \[(?P<type>[^\]]+)\].*methods=(?P<methods>\d+), "
    r"instructions=(?P<instructions>\d+), alloc=(?P<alloc>-?\d+)B, time=(?P<time>\d+)ms"
)


def repeat_to(pattern: str, n: int) -> str:
    return (pattern * ((n + len(pattern) - 1) // len(pattern)))[:n]


def random_dna(n: int, seed: int) -> str:
    rng = random.Random(seed)
    return "".join(rng.choice("ACGT") for _ in range(n))


def request(
    label: str,
    seq1: str,
    seq2: str,
    min_length: int,
    stop_on_first: bool,
    category: str,
) -> dict:
    return {
        "label": label,
        "seq1": seq1,
        "seq2": seq2,
        "minLength": min_length,
        "stopOnFirst": stop_on_first,
        "category": category,
    }


def build_requests() -> list[dict]:
    reqs: list[dict] = []

    for n in [100, 200, 500, 1000]:
        reqs.append(request(f"no_match_{n}", "A" * n, "C" * n, 8, False, "no_match"))

    for n in [100, 200, 500, 1000]:
        s = repeat_to("ACGT", n)
        reqs.append(request(f"full_match_{n}", s, s, 8, False, "full_match"))

    for n in [100, 500, 1000]:
        s = repeat_to("ACGT", n)
        reqs.append(request(f"full_match_stop_{n}", s, s, 8, True, "full_match_stop"))

    for n in [100, 200, 500]:
        seq1 = ("A" * max(0, n - 8)) + "TTTTTTTT"
        seq2 = ("C" * max(0, n - 8)) + "TTTTTTTT"
        reqs.append(request(f"late_match_{n}", seq1, seq2, 8, False, "late_match"))

    for n in [200, 500, 1000]:
        reqs.append(
            request(
                f"random_min4_{n}",
                random_dna(n, 1000 + n),
                random_dna(n, 2000 + n),
                4,
                False,
                "random_min4",
            )
        )

    for n in [200, 500, 1000]:
        reqs.append(
            request(
                f"random_min12_{n}",
                random_dna(n, 3000 + n),
                random_dna(n, 4000 + n),
                12,
                False,
                "random_min12",
            )
        )

    reqs.append(
        request("asym_1000_100", "A" * 1000, "C" * 100, 8, False, "asym_no_match")
    )
    reqs.append(
        request("asym_100_1000", "A" * 100, "C" * 1000, 8, False, "asym_no_match")
    )
    reqs.append(
        request(
            "short_min1",
            repeat_to("ATGC", 80),
            repeat_to("GCAT", 80),
            1,
            False,
            "minlength",
        )
    )
    reqs.append(
        request(
            "short_min20",
            repeat_to("ATGC", 80),
            repeat_to("GCAT", 80),
            20,
            False,
            "minlength",
        )
    )

    return reqs


def url_for(req: dict) -> str:
    params = {
        "seq1": "seq1:" + req["seq1"],
        "seq2": "seq2:" + req["seq2"],
        "minLength": str(req["minLength"]),
        "stopOnFirst": "true" if req["stopOnFirst"] else "false",
    }
    return f"http://localhost:{PORT}/dna?" + urllib.parse.urlencode(params)


def wait_ready() -> None:
    root = f"http://localhost:{PORT}/"
    for _ in range(30):
        try:
            with urllib.request.urlopen(root, timeout=1) as resp:
                if resp.status == 200:
                    return
        except Exception:
            time.sleep(1)
    raise RuntimeError("worker did not become ready")


def run_worker() -> subprocess.Popen:
    if not AGENT_JAR.exists() or not WS_JAR.exists():
        raise FileNotFoundError("missing JARs; run mvn -q package -DskipTests first")

    LOG.parent.mkdir(parents=True, exist_ok=True)
    log_f = LOG.open("w", encoding="utf-8")
    cmd = [
        "java",
        f"-javaagent:{AGENT_JAR}",
        "-cp",
        str(WS_JAR),
        "pt.ulisboa.tecnico.cnv.webserver.WebServer",
        str(PORT),
    ]
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=log_f, stderr=subprocess.STDOUT)
    proc._cnv_log_file = log_f  # type: ignore[attr-defined]
    return proc


def stop_worker(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    log_f = getattr(proc, "_cnv_log_file", None)
    if log_f is not None:
        log_f.close()


def send_requests(reqs: list[dict]) -> list[int]:
    http_times: list[int] = []
    for idx, req in enumerate(reqs, start=1):
        started = time.perf_counter()
        url = url_for(req)
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                resp.read()
                status = resp.status
        except Exception as exc:
            status = -1
            print(f"request failed: {req['label']}: {exc}", file=sys.stderr)
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        http_times.append(elapsed_ms)
        print(
            f"{idx:02d}/{len(reqs)} {req['label']:<22} HTTP {status} wall={elapsed_ms}ms"
        )
    return http_times


def parse_metrics() -> list[dict]:
    rows: list[dict] = []
    for line in LOG.read_text(encoding="utf-8", errors="replace").splitlines():
        m = METRICS_RE.match(line)
        if m:
            rows.append(
                {
                    "requestType": m.group("type"),
                    "methodCalls": int(m.group("methods")),
                    "instructions": int(m.group("instructions")),
                    "allocatedBytes": int(m.group("alloc")),
                    "elapsedMs": int(m.group("time")),
                }
            )
    return rows


def dna_seed_features(seq1: str, seq2: str, min_len: int) -> dict:
    if (
        min_len <= 0
        or len1_less_than_min(seq1, min_len)
        or len1_less_than_min(seq2, min_len)
    ):
        return {"seedPresenceScan": 0, "seedMisses": 0, "seedHits": 0, "seq2Kmers": 0}

    seq2_kmers = {seq2[j : j + min_len] for j in range(0, len(seq2) - min_len + 1)}
    full_scan = len(seq2) - min_len + 1
    presence_scan = 0
    misses = 0
    hits = 0
    for i in range(0, len(seq1) - min_len + 1):
        seed = seq1[i : i + min_len]
        if seed in seq2_kmers:
            # Present seeds are likely found without scanning the full seq2.
            presence_scan += 1
            hits += 1
        else:
            # Absent seeds force findSeed() to inspect all candidate positions.
            presence_scan += full_scan
            misses += 1
    return {
        "seedPresenceScan": presence_scan,
        "seedMisses": misses,
        "seedHits": hits,
        "seq2Kmers": len(seq2_kmers),
    }


def len1_less_than_min(seq: str, min_len: int) -> bool:
    return len(seq) < min_len


def features(req: dict) -> dict:
    len1 = len(req["seq1"])
    len2 = len(req["seq2"])
    min_len = int(req["minLength"])
    max_seq = max(len1, len2)
    sum_seq = len1 + len2
    product = len1 * len2
    search_space = max(0, len1 - min_len + 1) * max(0, len2 - min_len + 1)
    render_work = min(len1, 1000) + min(len2, 1000)
    seed_features = dna_seed_features(req["seq1"], req["seq2"], min_len)
    result = {
        "len1": len1,
        "len2": len2,
        "maxSeq": max_seq,
        "sumSeq": sum_seq,
        "product": product,
        "searchSpace": search_space,
        "renderWork": render_work,
        "minLength": min_len,
        "stopOnFirst": 1 if req["stopOnFirst"] else 0,
    }
    result.update(seed_features)
    return result


def mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)


def r2_single(x: list[float], y: list[float]) -> tuple[float, float, float]:
    mx = mean(x)
    my = mean(y)
    sxx = sum((v - mx) ** 2 for v in x)
    if sxx == 0:
        return 0.0, 0.0, my
    slope = sum((x[i] - mx) * (y[i] - my) for i in range(len(x))) / sxx
    intercept = my - slope * mx
    pred = [intercept + slope * v for v in x]
    return r2(y, pred), slope, intercept


def solve_linear_system(a: list[list[float]], b: list[float]) -> list[float]:
    n = len(b)
    for i in range(n):
        pivot = max(range(i, n), key=lambda r: abs(a[r][i]))
        if abs(a[pivot][i]) < 1e-12:
            raise ValueError("singular matrix")
        if pivot != i:
            a[i], a[pivot] = a[pivot], a[i]
            b[i], b[pivot] = b[pivot], b[i]
        div = a[i][i]
        for c in range(i, n):
            a[i][c] /= div
        b[i] /= div
        for r in range(n):
            if r == i:
                continue
            factor = a[r][i]
            for c in range(i, n):
                a[r][c] -= factor * a[i][c]
            b[r] -= factor * b[i]
    return b


def r2_multi(xs: list[list[float]], y: list[float]) -> tuple[float, list[float]]:
    cols = len(xs[0]) + 1
    xtx = [[0.0 for _ in range(cols)] for _ in range(cols)]
    xty = [0.0 for _ in range(cols)]
    for row, target in zip(xs, y):
        v = [1.0] + row
        for i in range(cols):
            xty[i] += v[i] * target
            for j in range(cols):
                xtx[i][j] += v[i] * v[j]
    beta = solve_linear_system([r[:] for r in xtx], xty[:])
    pred = [beta[0] + sum(beta[i + 1] * row[i] for i in range(len(row))) for row in xs]
    return r2(y, pred), beta


def r2(y: list[float], pred: list[float]) -> float:
    my = mean(y)
    ss_tot = sum((v - my) ** 2 for v in y)
    ss_res = sum((y[i] - pred[i]) ** 2 for i in range(len(y)))
    if ss_tot == 0:
        return 0.0
    return 1.0 - ss_res / ss_tot


def analyze(rows: list[dict]) -> str:
    y_instr = [float(r["instructions"]) for r in rows]
    y_alloc = [float(r["allocatedBytes"]) for r in rows]
    y_methods = [float(r["methodCalls"]) for r in rows]

    feature_names = [
        "maxSeq",
        "sumSeq",
        "product",
        "searchSpace",
        "seedPresenceScan",
        "seedMisses",
        "seedHits",
        "seq2Kmers",
        "renderWork",
        "minLength",
        "stopOnFirst",
    ]
    lines: list[str] = []
    lines.append("Single-feature R^2 for instructionCount")
    for name in feature_names:
        x = [float(r[name]) for r in rows]
        score, slope, intercept = r2_single(x, y_instr)
        lines.append(
            f"  {name:<12} R2={score:7.4f} slope={slope:12.4f} intercept={intercept:12.1f}"
        )

    lines.append("")
    lines.append("Two-feature R^2 for instructionCount")
    combos = [
        ("seedPresenceScan", "renderWork"),
        ("seedPresenceScan", "sumSeq"),
        ("seedMisses", "sumSeq"),
        ("searchSpace", "renderWork"),
        ("searchSpace", "sumSeq"),
        ("product", "sumSeq"),
        ("maxSeq", "searchSpace"),
        ("methodCalls", "allocatedBytes"),
    ]
    for a, b in combos:
        xs = [[float(r[a]), float(r[b])] for r in rows]
        score, beta = r2_multi(xs, y_instr)
        lines.append(f"  {a}+{b:<18} R2={score:7.4f} beta={beta}")

    lines.append("")
    lines.append("Single-feature R^2 for allocatedBytes")
    for name in [
        "maxSeq",
        "sumSeq",
        "renderWork",
        "product",
        "searchSpace",
        "seedPresenceScan",
    ]:
        x = [float(r[name]) for r in rows]
        score, slope, intercept = r2_single(x, y_alloc)
        lines.append(
            f"  {name:<12} R2={score:7.4f} slope={slope:12.4f} intercept={intercept:12.1f}"
        )

    lines.append("")
    lines.append("Single-feature R^2 for methodCallCount")
    for name in feature_names:
        x = [float(r[name]) for r in rows]
        score, slope, intercept = r2_single(x, y_methods)
        lines.append(
            f"  {name:<12} R2={score:7.4f} slope={slope:12.4f} intercept={intercept:12.1f}"
        )

    return "\n".join(lines)


def write_csv(rows: list[dict]) -> None:
    fields = [
        "idx",
        "label",
        "category",
        "len1",
        "len2",
        "minLength",
        "stopOnFirst",
        "maxSeq",
        "sumSeq",
        "product",
        "searchSpace",
        "seedPresenceScan",
        "seedMisses",
        "seedHits",
        "seq2Kmers",
        "renderWork",
        "methodCalls",
        "instructions",
        "allocatedBytes",
        "elapsedMs",
        "httpElapsedMs",
    ]
    with CSV_OUT.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: r.get(k, "") for k in fields})


def main() -> int:
    reqs = build_requests()
    proc = run_worker()
    try:
        wait_ready()
        print(f"worker ready on port {PORT}")
        http_times = send_requests(reqs)
        time.sleep(2)
    finally:
        stop_worker(proc)

    metric_rows = parse_metrics()
    if len(metric_rows) != len(reqs):
        print(
            f"warning: expected {len(reqs)} metrics, got {len(metric_rows)}",
            file=sys.stderr,
        )

    rows: list[dict] = []
    for idx, req in enumerate(reqs):
        row = {"idx": idx + 1, "label": req["label"], "category": req["category"]}
        row.update(features(req))
        if idx < len(metric_rows):
            row.update(metric_rows[idx])
        row["httpElapsedMs"] = http_times[idx] if idx < len(http_times) else ""
        rows.append(row)

    write_csv(rows)
    summary = analyze(rows)
    SUMMARY_OUT.write_text(summary + "\n", encoding="utf-8")
    print("\n" + summary)
    print(f"\nCSV: {CSV_OUT}")
    print(f"Summary: {SUMMARY_OUT}")
    print(f"Log: {LOG}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
