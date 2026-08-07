"""Correct inference-perf output-token metrics using server-reported usage.

inference-perf derives the output token count -- and the per-token latency
timeline -- by RE-TOKENIZING the generated text:

    output_len          = tokenizer.count_tokens(output_text)
    output_token_times  = <one entry per re-tokenized token>

With ``data.type: random`` + ``ignore_eos: true`` the detokenize -> retokenize
round-trip does not preserve the token count (random-token soup fragments on
re-encode), so ``output_len`` is inflated by a variable factor (~1.7-2.0x in
practice). Everything derived from it is therefore wrong:

  * ``requests.output_length``            -- inflated
  * ``throughput.output_token_rate``      -- inflated
  * ``throughput.total_token_rate``       -- inflated (output portion)
  * ``latency.normalized_time_per_output_token`` -- deflated (bigger denominator)
  * ``latency.time_per_output_token``     -- deflated
  * ``latency.inter_token_latency``       -- deflated (timeline over-sampled)

The vLLM server reports the exact generated count in ``usage.completion_tokens``,
which inference-perf captures per request as
``info.response_info.server_usage.completion_tokens`` but does not use for its
report. This module recomputes the true output-length distribution from server
usage and rescales every output-token-derived field in the generated Benchmark
Report v0.2 YAMLs. Measured fields (request rate, input length, request latency,
TTFT) are left untouched. Native inference-perf JSON output is left as-is.

The correction is per-report and idempotent: a report already carrying the
``output_token_correction`` annotation is skipped.
"""

from __future__ import annotations

import glob
import json
import re
from pathlib import Path

try:  # pyyaml is a hard dep of the analysis package; guard just in case
    import yaml
except Exception:  # pragma: no cover
    yaml = None

# Percentile stat-key -> quantile (percent). Matches the keys native_to_br0_2
# emits for Statistics blocks.
_PCT = {
    "p0p1": 0.1,
    "p1": 1.0,
    "p5": 5.0,
    "p10": 10.0,
    "p25": 25.0,
    "p50": 50.0,
    "median": 50.0,
    "p75": 75.0,
    "p90": 90.0,
    "p95": 95.0,
    "p99": 99.0,
    "p99p9": 99.9,
}

_MARKER = "output_token_correction"

# The exact vLLM-reported generated-token count, captured per request under
# info.response_info.server_usage.completion_tokens. Extracted by streaming
# regex rather than json.load: the per-request file is routinely multi-GB
# (dominated by per-token timelines + response text) and must not be loaded
# whole. completion_tokens appears exactly once per request in server_usage.
_CT_RE = re.compile(rb'"completion_tokens"\s*:\s*(\d+)')
_SCAN_CHUNK = 8 << 20  # 8 MiB
_SCAN_OVERLAP = 64  # > longest match; guards matches split across chunk boundary

# Fields to rescale, and the exponent applied to the per-stage factor f
# (f = true_mean / reported_output_length_mean, so 0 < f < 1 for inflation).
#   output_token_rate  : counts/time  -> x f
#   *_per_output_token : time/count   -> x 1/f
_RATE_FIELDS = ("output_token_rate",)
_PERTOKEN_FIELDS = (
    "normalized_time_per_output_token",
    "time_per_output_token",
    "inter_token_latency",
)


def _percentile(sorted_vals: list[float], q: float) -> float:
    """Linear-interpolation percentile (q in [0, 100]); numpy-free."""
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    rank = (q / 100.0) * (len(sorted_vals) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = rank - lo
    return float(sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac)


def _stats_like(existing: dict, values: list[float]) -> dict:
    """Rebuild a Statistics dict with the same keys as ``existing`` from raw
    ``values``. Unknown/non-numeric keys (e.g. ``units``) are passed through."""
    sv = sorted(values)
    n = len(sv)
    mean = sum(sv) / n if n else 0.0
    out: dict = {}
    for k, v in existing.items():
        if k == "mean":
            out[k] = mean
        elif k == "min":
            out[k] = float(sv[0]) if n else 0.0
        elif k == "max":
            out[k] = float(sv[-1]) if n else 0.0
        elif k == "stddev":
            var = sum((x - mean) ** 2 for x in sv) / n if n else 0.0
            out[k] = var ** 0.5
        elif k in _PCT:
            out[k] = _percentile(sv, _PCT[k])
        else:
            out[k] = v  # units, count, or anything non-statistical
    return out


def _scale_stats(block: dict, factor: float) -> None:
    """Multiply every numeric stat in a Statistics dict by ``factor`` in place."""
    for k, v in block.items():
        if k in ("units",):
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            block[k] = v * factor


def _per_request_file(results_dir: Path) -> Path | None:
    pr = results_dir / "per_request_lifecycle_metrics.json"
    if not pr.exists():
        pr = results_dir / "analysis" / "per_request_lifecycle_metrics.json"
    return pr if pr.exists() else None


def _true_completion_tokens(pr_file: Path) -> list[float]:
    """Stream every ``server_usage.completion_tokens`` value out of the
    per-request file in constant memory.

    Reads fixed-size binary chunks and regex-scans them, carrying a small
    overlap between chunks so a value straddling a boundary is neither missed
    nor double-counted. Never loads the (multi-GB) file whole.
    """
    vals: list[float] = []
    carry = b""
    with open(pr_file, "rb") as f:
        while True:
            chunk = f.read(_SCAN_CHUNK)
            if not chunk:
                for m in _CT_RE.finditer(carry):  # final flush; no overlap at EOF
                    vals.append(float(int(m.group(1))))
                break
            data = carry + chunk
            boundary = len(data) - _SCAN_OVERLAP
            for m in _CT_RE.finditer(data):
                if m.end() <= len(data) - _SCAN_OVERLAP:
                    vals.append(float(int(m.group(1))))
                else:
                    # First match reaching into the overlap tail: defer it and
                    # everything after by carrying from its start (matches are
                    # position-ordered, so the rest are further right).
                    boundary = m.start()
                    break
            carry = data[boundary:]
    return vals


def correct_inference_perf_output_tokens(results_dir, context=None) -> str | None:
    """Rescale output-token-derived metrics in v0.2 reports using server usage.

    Returns ``None`` on success (including "nothing to do"), or a short error
    string. Never raises for expected-missing inputs.
    """
    if yaml is None:
        return "pyyaml unavailable"
    results_dir = Path(results_dir)

    # Load the (small) v0.2 reports first and keep only those not already
    # corrected, so a re-analysis skips the expensive per-request scan entirely.
    reports = sorted(glob.glob(str(results_dir / "benchmark_report_v0.2,_*.yaml")))
    pending: list[tuple[Path, dict]] = []
    for rp in reports:
        doc = yaml.safe_load(Path(rp).read_text())
        if isinstance(doc, dict) and _MARKER not in doc:
            pending.append((Path(rp), doc))
    if not pending:
        return None  # nothing to correct

    pr_file = _per_request_file(results_dir)
    if pr_file is None:
        return None  # no per-request usage data -- nothing to correct
    true_vals = _true_completion_tokens(pr_file)
    if not true_vals:
        return None
    true_mean = sum(true_vals) / len(true_vals)
    if true_mean <= 0:
        return "true output-token mean is zero"

    per_report: list[dict] = []
    corrected = 0
    for rpath, doc in pending:
        try:
            agg = doc["results"]["request_performance"]["aggregate"]
        except (KeyError, TypeError):
            continue
        reqs = agg.get("requests") or {}
        thr = agg.get("throughput") or {}
        lat = agg.get("latency") or {}
        ol = reqs.get("output_length")
        if not isinstance(ol, dict) or ol.get("mean") in (None, 0):
            continue
        rep_mean = float(ol["mean"])
        f = true_mean / rep_mean  # < 1 when inflated
        if not (0 < f < 100):
            continue

        # 1. output_length -> true distribution (stage-independent sampler)
        reqs["output_length"] = _stats_like(ol, true_vals)

        # 2. throughput rate fields: counts/time -> x f
        for field in _RATE_FIELDS:
            if isinstance(thr.get(field), dict):
                _scale_stats(thr[field], f)

        # 3. total_token_rate: total - output*(1 - f) per matching stat key
        tot = thr.get("total_token_rate")
        if isinstance(tot, dict):
            # reconstruct pre-scaled output rate = post-scaled / f
            post = thr.get("output_token_rate") or {}
            for k, tv in list(tot.items()):
                if k == "units" or not isinstance(tv, (int, float)) or isinstance(tv, bool):
                    continue
                ov_post = post.get(k)
                if isinstance(ov_post, (int, float)) and not isinstance(ov_post, bool):
                    ov_pre = ov_post / f if f else 0.0
                    tot[k] = tv - ov_pre * (1 - f)

        # 4. per-token latencies: time/count -> x 1/f
        inv = 1.0 / f
        for field in _PERTOKEN_FIELDS:
            if isinstance(lat.get(field), dict):
                _scale_stats(lat[field], inv)

        doc[_MARKER] = {
            "source": "vllm usage.completion_tokens",
            "reason": "inference-perf output_len re-tokenizes generated text; "
            "inflated with random data + ignore_eos",
            "true_output_len_mean": round(true_mean, 3),
            "reported_output_len_mean": round(rep_mean, 3),
            "inflation_factor": round(rep_mean / true_mean, 4),
            "n_requests": len(true_vals),
            "fields_rescaled": list(_RATE_FIELDS)
            + ["total_token_rate"]
            + list(_PERTOKEN_FIELDS)
            + ["output_length (recomputed)"],
        }
        rpath.write_text(
            yaml.dump(
                doc,
                default_flow_style=False,
                allow_unicode=True,
                sort_keys=False,
            )
        )
        per_report.append(
            {
                "report": rpath.name,
                "reported_output_len_mean": round(rep_mean, 3),
                "inflation_factor": round(rep_mean / true_mean, 4),
            }
        )
        corrected += 1

    # Representative inflation for logs/audit: mean reported / true across the
    # corrected reports (reports are per-stage; the sampler is stage-independent
    # so true_mean is shared).
    global_ratio = (
        sum(r["reported_output_len_mean"] for r in per_report) / len(per_report) / true_mean
        if per_report
        else 1.0
    )

    # audit trail under metrics/processed
    audit = {
        "true_output_len_mean": true_mean,
        "n_requests": len(true_vals),
        "global_inflation_factor": round(global_ratio, 4),
        "reports_corrected": corrected,
        "per_report": per_report,
    }
    proc = results_dir / "metrics" / "processed"
    try:
        proc.mkdir(parents=True, exist_ok=True)
        (proc / "output_token_correction.json").write_text(json.dumps(audit, indent=2))
    except OSError:
        pass

    if context is not None and hasattr(context, "logger"):
        context.logger.log_info(
            f"Corrected output-token metrics in {corrected} report(s) "
            f"(inflation ~{global_ratio:.2f}x, n={len(true_vals)})",
            emoji="🔧",
        )
    return None
