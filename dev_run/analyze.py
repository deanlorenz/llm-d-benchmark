#!/usr/bin/env python3
"""
vLLM benchmark aggregator — tokens/sec focus, robust percentiles
(Produces comparative multi-panel charts across all experiments.)

Outputs:
  - analysis_metrics.csv
  - throughput_vs_latency.png
  - latency_vs_qps.png
  - throughput_vs_qps.png
  - benchmark_report.md
"""

import os
import re
import json
import glob
import argparse
from typing import Dict, Any, List, Optional, Tuple

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Plot sizing
FIGSIZE = (6, 4)
MULTI_FIGSIZE = (18, 4)   # for 1x3 panels
DPI = 110
LEGEND_FONTSIZE = 8


# ----------------------------- file discovery & parsing -----------------------------

def find_stage_files(root: str) -> List[str]:
    patterns = [
        os.path.join(root, "**", "results", "*", "stage_*_lifecycle_metrics.json"),
        os.path.join(root, "**", "stage_*_lifecycle_metrics.json"),
    ]
    files: List[str] = []
    for pat in patterns:
        files.extend(glob.glob(pat, recursive=True))
    return sorted(set(files))


def top_level_label(base_dir: str, path: str) -> str:
    """First segment under base_dir becomes the experiment label."""
    rel = os.path.relpath(os.path.dirname(path), base_dir)
    parts = [p for p in rel.split(os.sep) if p and p != "."]
    return parts[0] if parts else os.path.basename(os.path.dirname(path)) or "root"


def _read_per_request_stats(stage_dir: str) -> Dict[str, Any]:
    """
    Read <stage_dir>/per_request_lifecycle_metrics.json and return:
      - input_tokens_total (successes only)
      - output_tokens_total (successes only)
      - ttft_p50_s_computed, ttft_p90_s_computed
      - itl_p50_s_computed,  itl_p90_s_computed

    Handles JSON array or newline-delimited JSON. Ignores requests with non-null 'error'.

    Token timing note:
      Some emitters log output_token_times as start/end pairs [t1, t1, t2, t2, ...].
      We treat token start times as times[::2] when the first two entries are equal.
    """
    path = os.path.join(stage_dir, "per_request_lifecycle_metrics.json")
    stats = {
        "input_tokens_total": 0,
        "output_tokens_total": 0,
        "ttft_p50_s_computed": None,
        "ttft_p90_s_computed": None,
        "itl_p50_s_computed": None,
        "itl_p90_s_computed": None,
    }
    if not os.path.exists(path):
        return stats

    def _iter_requests(text: str):
        if not text:
            return
        if text.lstrip().startswith("["):
            try:
                data = json.loads(text)
                if isinstance(data, list):
                    for obj in data:
                        yield obj
                return
            except Exception:
                pass
        # Fallback: NDJSON
        for line in text.splitlines():
            line = line.strip().rstrip(",")
            if not line or line in ("[", "]"):
                continue
            try:
                yield json.loads(line)
            except Exception:
                continue

    ttft_samples: List[float] = []
    itl_samples: List[float] = []

    try:
        with open(path, "r") as f:
            text = f.read()
        for obj in _iter_requests(text):
            if not isinstance(obj, dict) or obj.get("error") is not None:
                continue
            info = obj.get("info", {}) or {}
            stats["input_tokens_total"] += int(info.get("input_tokens", 0) or 0)
            stats["output_tokens_total"] += int(info.get("output_tokens", 0) or 0)

            start_time = obj.get("start_time", None)
            tok_times = info.get("output_token_times", []) or []
            if not isinstance(tok_times, list) or not tok_times:
                continue
            # Extract token start times
            if len(tok_times) >= 2 and tok_times[0] == tok_times[1]:
                token_starts = tok_times[::2]
            else:
                token_starts = tok_times
            # TTFT: first token start - start_time
            if start_time is not None and len(token_starts) >= 1:
                ttft = float(token_starts[0]) - float(start_time)
                if ttft >= 0:
                    ttft_samples.append(ttft)
            # ITL: diffs between successive token starts
            if len(token_starts) >= 2:
                for i in range(1, len(token_starts)):
                    d = float(token_starts[i]) - float(token_starts[i - 1])
                    if d >= 0:
                        itl_samples.append(d)
    except Exception:
        pass

    if ttft_samples:
        stats["ttft_p50_s_computed"] = float(np.percentile(ttft_samples, 50))
        stats["ttft_p90_s_computed"] = float(np.percentile(ttft_samples, 90))
    if itl_samples:
        stats["itl_p50_s_computed"] = float(np.percentile(itl_samples, 50))
        stats["itl_p90_s_computed"] = float(np.percentile(itl_samples, 90))

    return stats


def parse_stage_file(base_dir: str, path: str) -> Dict[str, Any]:
    with open(path, "r") as f:
        data = json.load(f)

    experiment = top_level_label(base_dir, path)
    m = re.match(r"stage_(\d+)_lifecycle_metrics\.json", os.path.basename(path))
    stage_index = int(m.group(1)) if m else None

    load = data.get("load_summary", {}) or {}
    succ = data.get("successes", {}) or {}
    fails = data.get("failures", {}) or {}
    lat  = succ.get("latency", {}) or {}

    ttf  = lat.get("time_to_first_token", {}) or {}
    itl  = lat.get("inter_token_latency", {}) or {}
    reqL = lat.get("request_latency", {}) or {}
    thr  = succ.get("throughput", {}) or {}

    # Stage-reported tokens/sec (preferred for plotting)
    itps_json = thr.get("input_tokens_per_sec")
    otps_json = thr.get("output_tokens_per_sec")
    ttps_json = thr.get("total_tokens_per_sec")

    successes = int(succ.get("count", 0) or 0)
    failures  = int(fails.get("count", 0) or 0)
    total     = successes + failures
    success_rate = (successes / total) if total else None

    stage_dir = os.path.dirname(path)
    pr_stats = _read_per_request_stats(stage_dir)

    # Fallbacks for bogus/missing percentiles
    ttft_p50_f = ttf.get("p50")
    ttft_p90_f = ttf.get("p90")
    itl_p50_f  = itl.get("p50")
    itl_p90_f  = itl.get("p90")

    if (itl_p50_f is None or float(itl_p50_f) == 0.0) and pr_stats.get("itl_p50_s_computed") is not None:
        itl_p50_f = pr_stats["itl_p50_s_computed"]
    if (itl_p90_f is None or float(itl_p90_f) == 0.0) and pr_stats.get("itl_p90_s_computed") is not None:
        itl_p90_f = pr_stats["itl_p90_s_computed"]

    if (ttft_p50_f is None or float(ttft_p50_f) == 0.0) and pr_stats.get("ttft_p50_s_computed") is not None:
        ttft_p50_f = pr_stats["ttft_p50_s_computed"]
    if (ttft_p90_f is None or float(ttft_p90_f) == 0.0) and pr_stats.get("ttft_p90_s_computed") is not None:
        ttft_p90_f = pr_stats["ttft_p90_s_computed"]

    return {
        "experiment": experiment,
        "stage_index": stage_index,
        "requested_qps": load.get("requested_rate"),
        "send_duration_s": load.get("send_duration"),

        "achieved_rps_json": thr.get("requests_per_sec"),
        # tokens/sec as recorded in the file (successes.throughput.*)
        "input_toks_per_sec_json": itps_json,
        "output_toks_per_sec_json": otps_json,
        "total_toks_per_sec_json": ttps_json,

        "ttft_mean_s": ttf.get("mean"),
        "ttft_p50_s":  ttft_p50_f,
        "ttft_p90_s":  ttft_p90_f,
        "itl_mean_s":  itl.get("mean"),
        "itl_p50_s":   itl_p50_f,
        "itl_p90_s":   itl_p90_f,
        "request_latency_p50_s": reqL.get("p50"),

        "successes": successes,
        "failures": failures,
        "success_rate": success_rate,

        # per-request totals
        "input_tokens_total": pr_stats["input_tokens_total"],
        "output_tokens_total": pr_stats["output_tokens_total"],

        "source_path": path,
    }


def build_stage_df(base_dir: str) -> pd.DataFrame:
    files = find_stage_files(base_dir)
    rows = [parse_stage_file(base_dir, p) for p in files]
    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(by=["experiment", "requested_qps", "stage_index"]).reset_index(drop=True)
    return df


# ------------------------------ aggregation (per QPS/experiment) -------------------

def aggregate_per_qps(df: pd.DataFrame, served_mode: str, cap_served: bool) -> pd.DataFrame:
    """
    Aggregate across all stage files with the same (experiment, requested_qps).
    """
    if df.empty:
        return df

    grp = (
        df.groupby(["experiment", "requested_qps"], as_index=False)
          .agg(
              successes=("successes", "sum"),
              failures=("failures", "sum"),
              duration_s=("send_duration_s", "sum"),
              achieved_rps_json=("achieved_rps_json", "mean"),
              ttft_mean_s=("ttft_mean_s", "mean"),
              itl_mean_s=("itl_mean_s", "mean"),
              ttft_p50_s=("ttft_p50_s", "mean"),
              ttft_p90_s=("ttft_p90_s", "mean"),
              itl_p50_s=("itl_p50_s", "mean"),
              itl_p90_s=("itl_p90_s", "mean"),
              input_tokens_total=("input_tokens_total", "sum"),
              output_tokens_total=("output_tokens_total", "sum"),
              input_toks_per_sec_json=("input_toks_per_sec_json", "mean"),
              output_toks_per_sec_json=("output_toks_per_sec_json", "mean"),
              total_toks_per_sec_json=("total_toks_per_sec_json", "mean"),
          )
    )
    grp["total_completed"] = grp["successes"] + grp["failures"]
    grp["success_rate"] = grp["successes"] / grp["total_completed"]

    grp["completed_rps_total"] = grp["total_completed"] / grp["duration_s"]
    grp["completed_rps_successes"] = grp["successes"] / grp["duration_s"]
    mode = (served_mode or "total").lower()
    if mode == "successes":
        grp["completed_rps"] = grp["completed_rps_successes"]
    elif mode == "json":
        grp["completed_rps"] = grp["achieved_rps_json"]
    else:
        grp["completed_rps"] = grp["completed_rps_total"]

    grp["output_toks_per_sec"] = grp["output_tokens_total"] / grp["duration_s"]
    grp["input_toks_per_sec"]  = grp["input_tokens_total"]  / grp["duration_s"]
    grp["total_toks_per_sec"]  = grp["output_toks_per_sec"] + grp["input_toks_per_sec"]

    # Prefer JSON-reported tokens/sec when present; treat +/-inf as NaN, fallback to derived totals/duration
    s_in  = grp["input_toks_per_sec_json"].replace([np.inf, -np.inf], np.nan)
    s_out = grp["output_toks_per_sec_json"].replace([np.inf, -np.inf], np.nan)
    s_tot = grp["total_toks_per_sec_json"].replace([np.inf, -np.inf], np.nan)

    grp["input_toks_per_sec_plot"] = np.where(pd.notna(s_in),  s_in,  grp["input_toks_per_sec"])
    grp["output_toks_per_sec_plot"] = np.where(pd.notna(s_out), s_out, grp["output_toks_per_sec"])
    grp["total_toks_per_sec_plot"] = np.where(pd.notna(s_tot), s_tot, grp["total_toks_per_sec"])

    # Normalized time per output token (s/token). Lower is better.
    grp["norm_time_per_output_token_s"] = np.where(
        grp["output_tokens_total"] > 0,
        grp["duration_s"] / grp["output_tokens_total"],
        np.nan
    )

    return grp


# ---------------------------------- 1x3 charts ------------------------------------

def _style_axes(ax, xlabel, ylabel, title):
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(True, which="both", linestyle=":")

def plot_throughput_vs_latency(agg: pd.DataFrame, outfile: str) -> None:
    if agg.empty:
        return
    fig, axes = plt.subplots(1, 3, figsize=MULTI_FIGSIZE, dpi=DPI)
    # Sort experiments by ascending TTFT mean (overall) if available
    sort_order = (
        agg.groupby("experiment")["ttft_mean_s"]
        .mean()
        .sort_values()
        .index.tolist()
    )
    for exp in sort_order:
        # exclude if success rate is lower than 90%
        # dp if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.9:
        if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.2:    
            continue

        sdf = agg[agg["experiment"] == exp].copy()
        sdf = sdf.dropna(subset=["output_toks_per_sec_plot"]).sort_values("requested_qps")
        if sdf.empty:
            continue
        axes[0].plot(sdf["norm_time_per_output_token_s"]*1000, sdf["output_toks_per_sec_plot"], marker="o", label=exp)
        axes[1].plot(sdf["ttft_mean_s"]*1000,                 sdf["output_toks_per_sec_plot"], marker="o", label="_nolegend_")
        axes[2].plot(sdf["itl_mean_s"]*1000,                  sdf["output_toks_per_sec_plot"], marker="o", label="_nolegend_")
    _style_axes(axes[0], "Mean Norm. Time (ms/token)", "Output Tokens/sec", "Throughput vs. Norm. Time per Output Token")
    _style_axes(axes[1], "Mean TTFT (ms)",             "Output Tokens/sec", "Throughput vs. Time to First Token (sorted by TTFT)")
    _style_axes(axes[2], "Mean ITL (ms)",              "Output Tokens/sec", "Throughput vs. Inter-Token Latency")
    fig.suptitle("Latency vs Throughput (non-shared prefix synthetic load)", y=1.02, fontsize=12)
    fig.legend(loc="upper right", fontsize=LEGEND_FONTSIZE)
    fig.tight_layout()
    fig.savefig(outfile, bbox_inches="tight")
    plt.close(fig)

def plot_latency_vs_qps(agg: pd.DataFrame, outfile: str) -> None:
    if agg.empty:
        return
    fig, axes = plt.subplots(1, 3, figsize=MULTI_FIGSIZE, dpi=DPI)
    # Sort experiments by ascending TTFT mean (overall) if available
    sort_order = (
        agg.groupby("experiment")["ttft_mean_s"]
        .mean()
        .sort_values()
        .index.tolist()
    )
    for exp in sort_order:
        # exclude if success rate is lower than 90%
        # dp if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.9:
        if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.2:    
            continue

        sdf = agg[agg["experiment"] == exp].copy()
        sdf = sdf.dropna(subset=["requested_qps"]).sort_values("requested_qps")
        if sdf.empty:
            continue
        axes[0].plot(sdf["requested_qps"], sdf["ttft_mean_s"]*1000, marker="o", label=exp)
        axes[1].plot(sdf["requested_qps"], sdf["norm_time_per_output_token_s"]*1000, marker="o", label="_nolegend_")
        axes[2].plot(sdf["requested_qps"], sdf["itl_mean_s"]*1000, marker="o", label="_nolegend_")
    _style_axes(axes[0], "QPS (requested rate)", "Mean TTFT (ms)", "Time to First Token vs. QPS")
    _style_axes(axes[1], "QPS (requested rate)", "Mean Norm. Time (ms/token)", "Norm. Time per Output Token vs. QPS")
    _style_axes(axes[2], "QPS (requested rate)", "Mean ITL (ms)", "Inter-Token Latency vs. QPS")
    fig.suptitle("Latency vs Request Rate (non-shared prefix synthetic load)", y=1.02, fontsize=12)
    fig.legend(loc="upper right", fontsize=LEGEND_FONTSIZE)
    fig.tight_layout()
    fig.savefig(outfile, bbox_inches="tight")
    plt.close(fig)

def plot_throughput_vs_qps(agg: pd.DataFrame, outfile: str) -> None:
    if agg.empty:
        return
    fig, axes = plt.subplots(1, 3, figsize=MULTI_FIGSIZE, dpi=DPI)
    # Sort experiments by ascending TTFT mean (overall) if available
    sort_order = (
        agg.groupby("experiment")["ttft_mean_s"]
        .mean()
        .sort_values()
        .index.tolist()
    )
    for exp in sort_order:
        # exclude if success rate is lower than 90%
        # dp if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.9:
        if agg.loc[agg["experiment"] == exp, "success_rate"].mean() < 0.2:
            continue

        sdf = agg[agg["experiment"] == exp].copy()
        sdf = sdf.dropna(subset=["requested_qps"]).sort_values("requested_qps")
        # Drop rows where all preferred series are NaN
        sdf = sdf.dropna(
            subset=["input_toks_per_sec_plot", "output_toks_per_sec_plot", "total_toks_per_sec_plot"],
            how="all"
        )
        if sdf.empty:
            continue
        axes[0].plot(sdf["requested_qps"], sdf["input_toks_per_sec_plot"],  marker="o", label=exp)
        axes[1].plot(sdf["requested_qps"], sdf["output_toks_per_sec_plot"], marker="o", label="_nolegend_")
        axes[2].plot(sdf["requested_qps"], sdf["total_toks_per_sec_plot"],  marker="o", label="_nolegend_")
    _style_axes(axes[0], "QPS (requested rate)", "Tokens/sec", "Input Tokens/sec vs. QPS")
    _style_axes(axes[1], "QPS (requested rate)", "Tokens/sec", "Output Tokens/sec vs. QPS")
    _style_axes(axes[2], "QPS (requested rate)", "Tokens/sec", "Total Tokens/sec vs. QPS")
    fig.suptitle("Throughput vs Request Rate (non-shared prefix synthetic load)", y=1.02, fontsize=12)
    fig.legend(loc="upper right", fontsize=LEGEND_FONTSIZE)
    fig.tight_layout()
    fig.savefig(outfile, bbox_inches="tight")
    plt.close(fig)


# ------------------------------ config discovery -----------------------------------

def discover_profile_yaml(base_dir: str, profile_name: Optional[str]) -> Optional[str]:
    """
    Find <experiment>/workload/profiles/<profile_name>/*.yaml (first match).
    If profile_name is None, return the first YAML under any workload/profiles/*/.
    """
    patterns = []
    if profile_name:
        patterns.append(os.path.join(base_dir, "*", "workload", "profiles", profile_name, "*.yaml"))
    else:
        patterns.append(os.path.join(base_dir, "*", "workload", "profiles", "*", "*.yaml"))

    for pat in patterns:
        matches = sorted(glob.glob(pat))
        if matches:
            return matches[0]
    return None


def read_text_if_exists(path: Optional[str]) -> Optional[str]:
    if path and os.path.exists(path):
        with open(path, "r") as f:
            return f.read()
    return None


def discover_epp_configs(base_dir: str) -> List[Tuple[str, str]]:
    """Return list of (experiment_label, epp_config_path) for each <experiment>/epp_config.yaml."""
    results: List[Tuple[str, str]] = []
    for exp_dir in sorted(glob.glob(os.path.join(base_dir, "*"))):
        if not os.path.isdir(exp_dir):
            continue
        epp = os.path.join(exp_dir, "epp_config.yaml")
        if os.path.exists(epp):
            results.append((os.path.basename(exp_dir), epp))
    return results


# --------------------------------- markdown report ---------------------------------

FIELD_DESCRIPTIONS = [
    ("requested_qps", "Target request rate configured for the stage (requests/sec)."),
    ("duration_s", "Total time the load generator sent requests at this QPS (seconds, aggregated)."),
    ("successes", "Number of completed requests that succeeded (aggregated)."),
    ("failures", "Number of completed requests that failed (aggregated)."),
    ("success_rate", "Fraction of completed requests that succeeded: successes / (successes + failures). This captures outcome quality, not volume of work."),
    ("completed_rps", "Completed requests per second over the send window (basis set by --served-mode): total=(successes+failures)/s, successes=successes/s, json=value recorded in the file."),
    ("output_tokens_total", "Total number of output tokens generated (from per-request files; successes only)."),
    ("input_tokens_total", "Total number of input tokens ingested (from per-request files; successes only)."),
    ("output_toks_per_sec", "Primary throughput metric: output tokens generated per second across the stage window."),
    ("input_toks_per_sec", "Input tokens processed per second across the stage window."),
    ("norm_time_per_output_token_s", "Normalized time per output token (seconds/token). Lower is better."),
    ("ttft_mean_s", "Mean time to first token across successful requests (seconds). Lower is better."),
    ("ttft_p50_s", "TTFT median (p50) across successful requests (seconds). Lower is better."),
    ("ttft_p90_s", "TTFT 90th percentile (p90) across successful requests (seconds). Lower is better."),
    ("itl_mean_s", "Mean inter-token latency across successful requests (seconds). Lower is better."),
    ("itl_p50_s", "Inter-token latency median (p50) across successful requests (seconds). Lower is better."),
    ("itl_p90_s", "Inter-token latency 90th percentile (p90) across successful requests (seconds). Lower is better."),
    ("ttft_delta_vs_baseline_pct", "TTFT change vs baseline experiment: (TTFT - baseline_TTFT) / baseline_TTFT × 100. Negative = faster/better; positive = slower."),
    ("achieved_rps_json", "Throughput value recorded inside each stage file (successes.throughput.requests_per_sec). Useful for comparison/debugging; may omit failed requests depending on how the file was produced."),
]


def _build_summary_across_qps(agg: pd.DataFrame, served_mode: str, cap_served: bool,
                              baseline: Optional[str]) -> pd.DataFrame:
    """
    Build one-row-per-experiment summary across all QPS.
    """
    if agg.empty:
        return agg.copy()

    total_duration = agg.groupby("experiment")["duration_s"].sum(min_count=1)
    succ_sum = agg.groupby("experiment")["successes"].sum(min_count=1)
    fail_sum = agg.groupby("experiment")["failures"].sum(min_count=1)
    total_completed = succ_sum + fail_sum

    # Overall completed RPS
    if served_mode == "json":
        completed_rps_overall = (agg["achieved_rps_json"] * agg["duration_s"]).groupby(agg["experiment"]).sum(min_count=1) / total_duration
    elif served_mode == "successes":
        completed_rps_overall = succ_sum / total_duration
    else:
        completed_rps_overall = total_completed / total_duration

    # Tokens totals and tokens/sec (overall)
    out_tok_sum = agg.groupby("experiment")["output_tokens_total"].sum(min_count=1)
    in_tok_sum  = agg.groupby("experiment")["input_tokens_total"].sum(min_count=1)
    output_toks_per_sec_overall = out_tok_sum / total_duration
    input_toks_per_sec_overall  = in_tok_sum / total_duration

    # Prefer JSON-reported overall means when present
    otps_json_overall = agg.groupby("experiment")["output_toks_per_sec_json"].mean()
    itps_json_overall = agg.groupby("experiment")["input_toks_per_sec_json"].mean()
    output_toks_per_sec_overall = otps_json_overall.fillna(output_toks_per_sec_overall)
    input_toks_per_sec_overall  = itps_json_overall.fillna(input_toks_per_sec_overall)

    # Weighted TTFT/ITL means
    ttft_num = (agg["ttft_mean_s"] * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    itl_num  = (agg["itl_mean_s"]  * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    ttft_overall = (ttft_num / succ_sum).replace([np.inf, -np.inf], np.nan)
    itl_overall  = (itl_num  / succ_sum).replace([np.inf, -np.inf], np.nan)

    # Weighted percentiles (approx)
    ttft_p50_num = (agg["ttft_p50_s"] * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    ttft_p90_num = (agg["ttft_p90_s"] * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    itl_p50_num  = (agg["itl_p50_s"]  * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    itl_p90_num  = (agg["itl_p90_s"]  * agg["successes"]).groupby(agg["experiment"]).sum(min_count=1)
    ttft_p50_overall = (ttft_p50_num / succ_sum).replace([np.inf, -np.inf], np.nan)
    ttft_p90_overall = (ttft_p90_num / succ_sum).replace([np.inf, -np.inf], np.nan)
    itl_p50_overall  = (itl_p50_num  / succ_sum).replace([np.inf, -np.inf], np.nan)
    itl_p90_overall  = (itl_p90_num  / succ_sum).replace([np.inf, -np.inf], np.nan)

    success_rate_overall = succ_sum / total_completed

    summary = pd.DataFrame({
        "experiment": succ_sum.index,
        "qps_points": agg.groupby("experiment")["requested_qps"].nunique().values,
        "successes": succ_sum.values,
        "failures": fail_sum.values,
        "duration_s": total_duration.values,
        "completed_rps_overall": completed_rps_overall.values,
        "output_tokens_total": out_tok_sum.values,
        "input_tokens_total": in_tok_sum.values,
        "output_toks_per_sec_overall": output_toks_per_sec_overall.values,
        "input_toks_per_sec_overall": input_toks_per_sec_overall.values,
        "ttft_mean_s_overall": ttft_overall.values,
        "itl_mean_s_overall": itl_overall.values,
        "ttft_p50_s_overall": ttft_p50_overall.values,
        "ttft_p90_s_overall": ttft_p90_overall.values,
        "itl_p50_s_overall": itl_p50_overall.values,
        "itl_p90_s_overall": itl_p90_overall.values,
        "success_rate_overall": success_rate_overall.values,
    })

    # Baseline delta on overall TTFT (negative = faster)
    if baseline and baseline in summary["experiment"].values:
        base_ttft = summary.loc[summary["experiment"] == baseline, "ttft_mean_s_overall"].iloc[0]
        if pd.notna(base_ttft) and base_ttft != 0:
            summary["ttft_delta_vs_baseline_pct_overall"] = ((summary["ttft_mean_s_overall"] - base_ttft) / base_ttft) * 100.0
        else:
            summary["ttft_delta_vs_baseline_pct_overall"] = pd.NA
    else:
        summary["ttft_delta_vs_baseline_pct_overall"] = pd.NA

    summary = summary.sort_values(
        by=["output_toks_per_sec_overall", "success_rate_overall", "ttft_mean_s_overall"],
        ascending=[False, False, True]
    ).reset_index(drop=True)
    return summary


def write_markdown_report_per_qps(
    agg: pd.DataFrame,
    out_dir: str,
    charts: Dict[str, str],
    profile_yaml_path: Optional[str],
    epp_configs: List[Tuple[str, str]],
    img_width_px: int,
    baseline: Optional[str],
    served_mode: str,
    cap_served: bool,
    title: str = "vLLM Benchmark Summary",
) -> str:
    os.makedirs(out_dir, exist_ok=True)
    md_path = os.path.join(out_dir, "benchmark_report.md")

    lines: List[str] = []
    lines.append(f"# {title}\n")

    if agg.empty:
        lines.append("_No data found._\n")
    else:
        # ---------- Charts ----------
        if charts:
            lines.append("## Charts\n")
            for title_, abs_path in charts.items():
                rel_path = os.path.relpath(abs_path, out_dir)
                if os.path.exists(abs_path):
                    lines.append(f"### {title_}\n")
                    lines.append(f'<img src="{rel_path}" alt="{title_}" width="{img_width_px}"/>\n')

        # ---------- How to read ----------
        lines.append("### How to read this report (quick)\n")
        lines.append("- **Output tokens/sec** is the primary throughput metric (higher is better).\n")
        lines.append("- **Requests/sec** shows the rate of completed requests.\n")
        lines.append("- **Success Rate** reflects outcome quality, not volume.\n")
        lines.append("- **TTFT** is time to first token; **ITL** is the gap between tokens (both lower is better).\n")
        lines.append("")

        # ---------- Field descriptions ----------
        lines.append("### Field descriptions\n")
        for k, desc in FIELD_DESCRIPTIONS:
            lines.append(f"- **{k}** — {desc}")
        lines.append("")

        # ---------- Summary across QPS ----------
        summary = _build_summary_across_qps(agg, served_mode=served_mode, cap_served=cap_served, baseline=baseline)
        lines.append("### Summary across QPS\n")
        lines.append("")
        lines.append("| Experiment | Output toks/s | Requests/s | Success Rate | TTFT mean (s) | TTFT p50/ p90 (s) | ITL mean (s) | ITL p50/ p90 (s) |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for _, r in summary.iterrows():
            toks = "" if pd.isna(r["output_toks_per_sec_overall"]) else f"{r['output_toks_per_sec_overall']:.1f}"
            rps  = "" if pd.isna(r["completed_rps_overall"]) else f"{r['completed_rps_overall']:.3f}"
            sr   = f"{r['success_rate_overall']:.2%}" if pd.notna(r["success_rate_overall"]) else "n/a"
            ttft = "" if pd.isna(r["ttft_mean_s_overall"]) else f"{r['ttft_mean_s_overall']:.3f}"
            itl  = "" if pd.isna(r["itl_mean_s_overall"]) else f"{r['itl_mean_s_overall']:.3f}"
            ttft_pct = "" if (pd.isna(r.get("ttft_p50_s_overall")) or pd.isna(r.get("ttft_p90_s_overall"))) else f"{r['ttft_p50_s_overall']:.3f}/{r['ttft_p90_s_overall']:.3f}"
            itl_pct  = "" if (pd.isna(r.get("itl_p50_s_overall")) or pd.isna(r.get("itl_p90_s_overall"))) else f"{r['itl_p50_s_overall']:.4f}/{r['itl_p90_s_overall']:.3f}"
            lines.append(f"| {r['experiment']} | {toks} | {rps} | {sr} | {ttft} | {ttft_pct} | {itl} | {itl_pct} |")

        # ---------- Per-QPS tables ----------
        lines.append("\n## Per-QPS Results (sorted by **Output toks/s**, then **Success Rate**, then **TTFT**)\n")
        for qps, qps_df in agg.groupby("requested_qps"):
            qps_df = qps_df.sort_values(
                by=["output_toks_per_sec", "success_rate", "ttft_mean_s"],
                ascending=[False, False, True]
            )
            lines.append(f"\n### QPS = {qps}\n")
            lines.append("")
            lines.append("| Experiment | Output toks/s | Requests/s | Success Rate | TTFT mean (s) | TTFT p50/ p90 (s) | ITL mean (s) | ITL p50/ p90 (s) |")
            lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
            for _, r in qps_df.iterrows():
                toks_val = r.get("output_toks_per_sec_plot", np.nan)
                toks = "" if pd.isna(toks_val) else f"{toks_val:.1f}"
                rps  = "" if pd.isna(r["completed_rps"]) else f"{r['completed_rps']:.3f}"
                sr   = f"{r['success_rate']:.2%}" if pd.notna(r["success_rate"]) else "n/a"
                ttft = "" if pd.isna(r["ttft_mean_s"]) else f"{r['ttft_mean_s']:.3f}"
                itl  = "" if pd.isna(r["itl_mean_s"]) else f"{r['itl_mean_s']:.3f}"
                ttft_pct = "" if (pd.isna(r.get("ttft_p50_s")) or pd.isna(r.get("ttft_p90_s"))) else f"{r['ttft_p50_s']:.3f}/{r['ttft_p90_s']:.3f}"
                itl_pct  = "" if (pd.isna(r.get("itl_p50_s")) or pd.isna(r.get("itl_p90_s"))) else f"{r['itl_p50_s']:.4f}/{r['itl_p90_s']:.3f}"
                lines.append(f"| {r['experiment']} | {toks} | {rps} | {sr} | {ttft} | {ttft_pct} | {itl} | {itl_pct} |")

    # Configuration
    lines.append("\n## Configuration\n")

    # Profile (shown once)
    lines.append("### Workload profile (shown once)\n")
    if profile_yaml_path:
        profile_text = read_text_if_exists(profile_yaml_path) or "(file unreadable)"
        lines.append("```yaml")
        lines.append(profile_text.rstrip())
        lines.append("```\n")
    else:
        lines.append("_No profile YAML found._\n")

    # EPP configs per experiment
    lines.append("### EPP config per experiment\n")
    epp_configs_sorted = sorted(epp_configs, key=lambda x: x[0])
    if epp_configs_sorted:
        for label, epp_path in epp_configs_sorted:
            epp_text = read_text_if_exists(epp_path) or "(file unreadable)"
            lines.append(f"**{label}**\n")
            lines.append("```yaml")
            lines.append(epp_text.rstrip())
            lines.append("```\n")
    else:
        lines.append("_No epp_config.yaml files found under experiments._\n")

    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    return md_path


# -------------------------------------- main ---------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-dir", required=True, help="Root folder containing experiment subfolders")
    ap.add_argument("--out-dir", default=None, help="Output directory (default: <base-dir>)")
    ap.add_argument("--profile-name", default=None,
                    help="Optional profile folder name under workload/profiles/ to display (otherwise first found)")
    ap.add_argument("--img-width", type=int, default=950, help="Image width (px) in the markdown report")
    ap.add_argument("--served-mode", choices=["total", "successes", "json"], default="total",
                    help="Throughput basis for completed RPS: total(completed), successes only, or JSON throughput")
    ap.add_argument("--no-cap-served", action="store_true",
                    help="(unused placeholder; kept for CLI stability)")
    ap.add_argument("--baseline", default=None, help="Experiment name to use as baseline for ΔTTFT (report tables only)")
    args = ap.parse_args()

    base_dir = os.path.abspath(args.base_dir)
    out_dir  = os.path.abspath(args.out_dir or base_dir)
    os.makedirs(out_dir, exist_ok=True)

    # 1) Stage-level data
    stage_df = build_stage_df(base_dir)

    # 2) Aggregate per QPS/experiment
    agg = aggregate_per_qps(stage_df, served_mode=args.served_mode, cap_served=not args.no_cap_served)

    # 3) Save CSV
    csv_path = os.path.join(out_dir, "analysis_metrics.csv")
    agg.to_csv(csv_path, index=False)

    # 4) Comparative 1x3 figures (like the attachments)
    charts = {
        "Latency vs Throughput": os.path.join(out_dir, "throughput_vs_latency.png"),
        "Latency vs QPS":       os.path.join(out_dir, "latency_vs_qps.png"),
        "Throughput vs QPS":    os.path.join(out_dir, "throughput_vs_qps.png"),
    }
    plot_throughput_vs_latency(agg, charts["Latency vs Throughput"])
    plot_latency_vs_qps(agg, charts["Latency vs QPS"])
    plot_throughput_vs_qps(agg, charts["Throughput vs QPS"])

    # 5) Discover profile + epp configs
    profile_yaml_path = discover_profile_yaml(base_dir, args.profile_name)
    epp_configs = discover_epp_configs(base_dir)

    # 6) Markdown report
    md_path = write_markdown_report_per_qps(
        agg, out_dir, charts, profile_yaml_path, epp_configs,
        img_width_px=args.img_width, baseline=args.baseline,
        served_mode=args.served_mode, cap_served=not args.no_cap_served
    )

    # 7) Console summary
    print("Wrote:")
    print("  CSV:      ", csv_path)
    for t, p in charts.items():
        print(f"  {t}: {p}")
    print("  Report MD:", md_path)


if __name__ == "__main__":
    main()