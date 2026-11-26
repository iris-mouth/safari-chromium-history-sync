#!/usr/bin/env python3
"""Synthetic local benchmark; Python is a development-only fixture generator."""
import argparse
import json
from datetime import datetime
from zoneinfo import ZoneInfo
import os
import platform
import sqlite3
import statistics
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ["HISTORY_BENCH_BIN"])
VIEWER = Path(os.environ["HISTORY_VIEWER_BIN"])
PORT = 18770


def generate(path, count):
    start = time.perf_counter()
    with sqlite3.connect(path) as db:
        db.executescript("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER);")
        db.executemany("INSERT INTO urls VALUES(?,?,?)", (
            (i, f"https://site{i}.example.test/article", "ＡＢＣ ｶﾞｯｺｳ ① ㎏" if i == 1 else f"調べ物 カタカナ {i}") for i in range(1, 1001)
        ))
        db.executemany("INSERT INTO visits VALUES(?,?,?)", (
            (i, ((i-1) % 1000) + 1, (1794268800 - ((i-1) % 20000) * 60 + 11644473600) * 1000000 + i % 1000000)
            for i in range(1, count + 1)
        ))
    return time.perf_counter() - start


def get(path):
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}" + path, headers={"Tailscale-User-Login": "owner@example.test"})
    start = time.perf_counter()
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read()
    return time.perf_counter() - start, json.loads(data), len(data)


def run(count, root):
    source = root / f"History-{count}"
    target_dir = root / f"output-{count}"
    target_dir.mkdir(mode=0o700)
    target = target_dir / "history.sqlite"
    generation = generate(source, count)
    worker = subprocess.Popen([str(BIN), str(source), str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    viewer = None
    try:
        line = worker.stdout.readline().strip()
        if not line.startswith("READY "):
            raise RuntimeError(f"collector failed: {line} {worker.stderr.read()}")
        _, collection, actual = line.split()
        if int(actual) != count:
            raise RuntimeError("wrong record count")
        viewer = subprocess.Popen([str(VIEWER), "--database", str(target), "--assets", str(ROOT / "web/dist"), "--owner", "owner@example.test", "--port", str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            if viewer.poll() is not None:
                raise RuntimeError("viewer did not start")
            try:
                get("/api/status")
                break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError("viewer did not become ready")
        date_path = "/api/records?scope=range&start=2026-11-10&end=2026-11-10&limit=200"
        search_path = "/api/records?" + urllib.parse.urlencode({"scope":"all", "q":"abc がっこう 1 kg", "limit":"200"})
        range_search_path = search_path + "&scope=range&start=2026-11-10&end=2026-11-10"
        range_search_path = range_search_path.replace("scope=all&", "")
        lower = int((datetime(2026, 11, 10, tzinfo=ZoneInfo("Asia/Tokyo")).timestamp() + 11644473600) * 1000000)
        upper = lower + 86400 * 1000000
        with sqlite3.connect(source) as db:
            range_matches = db.execute("SELECT count(*) FROM visits WHERE url=1 AND visit_time>=? AND visit_time<?", (lower, upper)).fetchone()[0]
        results = {}
        for label, path in (("day", date_path), ("search", search_path), ("all", "/api/records?scope=all&limit=200"), ("range_search", range_search_path)):
            samples = [get(path) for _ in range(4)]
            expected = min(range_matches, 200) if label == "range_search" else min(count // 1000, 200) if label == "search" else 200
            if any(len(sample[1]["items"]) != expected for sample in samples):
                raise RuntimeError(f"unexpected {label} result count; timing is invalid")
            results[label] = {"seconds": [round(s[0], 4) for s in samples], "median_seconds": round(statistics.median(s[0] for s in samples), 4), "items": len(samples[-1][1]["items"]), "response_bytes": samples[-1][2]}
        return {"records":count, "fixture_generation_seconds":round(generation, 3), "initial_collection_seconds":round(float(collection), 3), "queries":results}
    finally:
        for process in (viewer, worker):
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    document = {"conditions": {"date_local":datetime.now(ZoneInfo("Asia/Tokyo")).date().isoformat(), "platform":platform.platform(), "machine":platform.machine(), "python":platform.python_version(), "network":"localhost; separate Swift Viewer process", "cache":"fixture generation warms filesystem cache; four sequential requests", "search_wait_ms":0, "note":"Local synthetic measurement, not an iPhone or Tailscale target measurement."}, "results":[]}
    with tempfile.TemporaryDirectory(prefix="integrated-history-benchmark-") as tmp:
        for count in (100000, 1000000):
            print(f"Generating and collecting {count} synthetic visits...", flush=True)
            document["results"].append(run(count, Path(tmp)))
            print(json.dumps(document["results"][-1], ensure_ascii=False), flush=True)
    path = args.output
    path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {path}")
