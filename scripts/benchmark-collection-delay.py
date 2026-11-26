#!/usr/bin/env python3
"""Measure the 30 s scan cadence on a temporary, synthetic browser DB."""
import argparse
import importlib.util
import json
import os
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bench", ROOT / "scripts/benchmark-integrated.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="history-delay-") as tmp:
    root = Path(tmp)
    source = root / "History"
    targetdir = root / "data"
    targetdir.mkdir(mode=0o700)
    target = targetdir / "history.sqlite"
    bench.generate(source, 100000)
    worker = subprocess.Popen([str(bench.BIN), str(source), str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    viewer = None
    try:
        line = worker.stdout.readline().strip()
        if not line.startswith("READY "):
            raise RuntimeError("collector did not start: " + line)
        viewer = subprocess.Popen([str(bench.VIEWER), "--database", str(target), "--assets", str(ROOT / "web/dist"), "--owner", "owner@example.test", "--port", str(bench.PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                bench.get("/api/status")
                break
            except OSError:
                if viewer.poll() is not None: raise RuntimeError("viewer did not start")
                time.sleep(.1)
        else: raise RuntimeError("viewer did not become ready")
        old_url = "/api/records?scope=all&q=site2.example.test%2Farticle&limit=200"
        new_url = "/api/records?scope=all&q=fresh-arrival.example.test&limit=200"
        assert any(r["native_visit_id"] == 2 for r in bench.get(old_url)[1]["items"])
        with sqlite3.connect(source) as db:
            db.execute("INSERT INTO urls VALUES(1001,'https://fresh-arrival.example.test/page','Fresh arrival')")
            db.execute("INSERT INTO visits VALUES(100001,1001,?)", ((1794268800 + 11644473600) * 1000000,))
            db.execute("DELETE FROM visits WHERE id=2")
            db.commit()
        started = time.monotonic()
        new_delay = deletion_delay = None
        while time.monotonic() - started < 80:
            if new_delay is None and bench.get(new_url)[1]["items"]:
                new_delay = time.monotonic() - started
            if deletion_delay is None and not any(r["native_visit_id"] == 2 for r in bench.get(old_url)[1]["items"]):
                deletion_delay = time.monotonic() - started
            if new_delay is not None and deletion_delay is not None: break
            time.sleep(.5)
        result = {"conditions":"Synthetic 100,000-visit Chromium SQLite; a benchmark worker using the same 30-second full-scan interval as the Agent; localhost HTTP; one source; polling every 0.5 seconds. Timing begins immediately after the source transaction commits.", "new_visit_seconds":new_delay, "deletion_seconds":deletion_delay, "initial_collection_seconds":float(line.split()[1])}
        if new_delay is None or deletion_delay is None: raise RuntimeError("changes not observed within 80 seconds")
        path = args.output
        path.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
    finally:
        for process in (viewer, worker):
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
