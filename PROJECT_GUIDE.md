# AI-Assisted Network Traffic Forensics
### Intrusion Detection System — Complete Project Guide

---

## Table of Contents

1. [The Idea](#1-the-idea)
2. [System Blueprint](#2-system-blueprint)
3. [What It Does](#3-what-it-does)
4. [Project Structure](#4-project-structure)
5. [How to Run It](#5-how-to-run-it)
6. [What Happens When You Run It](#6-what-happens-when-you-run-it)
7. [File-by-File Code Breakdown](#7-file-by-file-code-breakdown)
   - [run.py — The Launcher](#runpy--the-launcher)
   - [pipeline/main.py — The Real-Time Pipeline](#pipelinemainpy--the-real-time-pipeline)
   - [pipeline/normalizer.py — The Event Schema](#pipelinenormalizerpy--the-event-schema)
   - [pipeline/correlator.py — The Event Correlator](#pipelinecorrelatorpy--the-event-correlator)
   - [pipeline/inference.py — The AI Classifier](#pipelineinferencepy--the-ai-classifier)
   - [ml/train_model.py — The Model Trainer](#mltrainmodelpy--the-model-trainer)

---

## 1. The Idea

> **One-line summary:** Watch all network traffic in real time, feed it to an AI, and raise an alarm if something looks like an attack.

Most cyber attacks leave traces in network traffic — unusual ports, large data transfers, known attack signatures. The problem is there is too much traffic for a human to watch manually.

This project automates that by combining three things:

| Layer | What it does |
|---|---|
| **Network sensors** | Zeek and Suricata watch traffic and write structured logs |
| **AI model** | A trained Random Forest classifies every connection as benign, suspicious, or malicious |
| **Pipeline** | Python glues it all together in real time and ships results to logs and ELK |

The result is a system that can spot DDoS attacks, malware communications, port scans, and unauthorized access — automatically — and explain *why* it flagged something.

---

## 2. System Blueprint

```
                        NETWORK TRAFFIC
                              |
              ┌───────────────┼───────────────┐
              |               |               |
           ZEEK            SURICATA       WIRESHARK
      (connection         (IDS alerts    (PCAP files /
       metadata)           + flows)       tshark)
              |               |               |
              └───────────────┼───────────────┘
                              |
                    ┌─────────▼─────────┐
                    │    NORMALIZER     │
                    │  unified schema   │
                    │ (every event gets │
                    │  same fields)     │
                    └─────────┬─────────┘
                              |
                    ┌─────────▼─────────┐
                    │    CORRELATOR     │
                    │  matches Suricata │
                    │  alerts to Zeek   │
                    │  flow data        │
                    └─────────┬─────────┘
                              |
                    ┌─────────▼─────────┐
                    │    ML ENGINE      │
                    │  Random Forest    │
                    │                   │
                    │  benign     0–40% │
                    │  suspicious 40–70%│
                    │  malicious  70%+  │
                    └─────────┬─────────┘
                              |
              ┌───────────────┼───────────────┐
              |               |               |
       CONSOLE ALERT     JSON LOG         ELK STACK
    (WARNING printed)  audit_events     (Kibana dashboard
                       .json + .csv      + Elasticsearch)
```

---

## 3. What It Does

### Step 1 — Capture
Zeek and Suricata sit on the network interface and write structured logs every time a connection is made. Zeek captures metadata (who connected to whom, how many bytes, how long). Suricata fires alerts when traffic matches known attack signatures.

### Step 2 — Normalize
Every log line from every sensor is different. The normalizer converts all of them into one consistent Python dictionary so the rest of the pipeline does not need to care about the source.

### Step 3 — Correlate
When Suricata fires an alert, it often lacks detailed flow data (bytes, duration). The correlator looks up whether Zeek saw the same connection (matched by src IP, dst IP, src port, dst port) and merges that data in — giving the AI richer features to work with.

### Step 4 — Classify
The AI model — a Random Forest trained on 2000 labeled network events — receives 11 numerical features extracted from the event and outputs a label plus a confidence score:

- **benign** — normal traffic, no action needed
- **suspicious** — unusual pattern, logged for review
- **malicious** — known attack behavior, console alarm raised immediately

It also explains its reasoning in plain English: *"High IDS severity | Anomalous high byte transfer | Suspicious destination port"*

### Step 5 — Output
Every classified event is written to:
- `data/logs/audit_events.json` — one JSON object per line, for ELK ingestion
- `data/logs/audit_events.csv` — spreadsheet format for manual review
- **Console** — WARNING printed for malicious, INFO for suspicious, stats every 50 events

### Step 6 — Visualize
Filebeat (configured in `elk/`) tails the JSON log and ships events to Elasticsearch. Kibana then lets you build dashboards showing traffic over time, alert counts, top attacker IPs, etc.

---

## 4. Project Structure

```
DigitalForensics/
│
├── run.py                        The single entry point for everything
├── check.py                      Health check — tests all components
├── requirements.txt              pip install -r requirements.txt
├── .env                          Configuration (log paths, ELK URLs)
├── docker-compose.elk.yml        Start Elasticsearch + Logstash + Kibana
│
├── pipeline/                     High-level real-time processing
│   ├── main.py                   Orchestrates all threads
│   ├── normalizer.py             Converts any log into unified schema
│   ├── correlator.py             Merges Zeek + Suricata on same flow
│   ├── inference.py              ML model wrapper — classifies events
│   ├── output_manager.py         Writes to JSON + CSV logs
│   ├── ingest_zeek.py            Tails Zeek conn.log
│   ├── ingest_suricata.py        Tails Suricata eve.json
│   └── ingest_wireshark.py       Parses PCAP files with tshark
│
├── ml/
│   ├── train_model.py            Trains the Random Forest model
│   └── models/
│       ├── rf_model.pkl          Trained model bundle (created after training)
│       └── model_metadata.json   Training metrics and feature list
│
├── detection-engine/             Low-level sensor stream handlers
│   ├── main.py                   Alternative entry (Zeek + Suricata + correlator)
│   ├── ai_engine.py              Full AI engine with safety overrides
│   ├── correlator.py             Correlation + detection loop
│   ├── zeek_stream.py            Zeek log reader
│   ├── suricata_stream.py        Suricata EVE reader
│   ├── dataset.csv               Labeled training dataset (2000 events)
│   └── models/                   Mirror model location
│
├── simulation/
│   ├── ingest_pcap.sh            Run Zeek + Suricata on an offline PCAP
│   └── tcpreplay_attack.sh       Replay attack traffic on a live interface
│
├── data/
│   ├── logs/                     All output lands here
│   │   ├── audit_events.json     Main enriched event log (JSON lines)
│   │   ├── audit_events.csv      Same events in CSV format
│   │   ├── zeek_offline/         Offline Zeek logs
│   │   └── suricata_offline/     Offline Suricata logs (sample data here)
│   └── pcaps/                    Put your .pcap capture files here
│
└── elk/
    ├── filebeat/                 Filebeat config — ships JSON log to ELK
    ├── logstash/                 Logstash pipeline config
    └── elasticsearch/            Index template
```

---

## 5. How to Run It

### Prerequisites

```
Python 3.10+
pip install -r requirements.txt
Docker (optional, for ELK visualisation)
```

---

### Step 1 — Train the AI Model

```bash
python run.py --mode train
```

Reads `detection-engine/dataset.csv` and trains a Random Forest classifier.
Saves the model to `ml/models/rf_model.pkl`.

> Only needs to be done once. The model persists on disk.

---

### Step 2 — (Optional) Start ELK for Visualisation

```bash
docker compose -f docker-compose.elk.yml up -d
```

| URL | What it is |
|---|---|
| http://127.0.0.1:5601 | Kibana — visual dashboards |
| http://127.0.0.1:9200 | Elasticsearch — event storage |

---

### Step 3 — Run the Real-Time Pipeline

```bash
python run.py --mode pipeline
```

Starts tailing logs and classifying every event that comes in.

---

### Step 4 — (Optional) Analyse a PCAP File

```bash
python run.py --mode pcap --pcap data/pcaps/your_capture.pcap
```

Requires `tshark` to be installed.

---

### Step 5 — Verify Everything Works

```bash
python check.py
```

---

## 6. What Happens When You Run It

### `python run.py --mode train`

```
Training Random Forest model from: detection-engine/dataset.csv

--- Model Evaluation ---
Accuracy:  0.8950
Precision: 0.8917
Recall:    0.8950
F1-Score:  0.8918

               precision    recall  f1-score
      benign       0.93      0.96      0.94
   malicious       0.82      0.69      0.75
  suspicious       0.90      0.95      0.92

[OK] Model bundle saved to ml/models/rf_model.pkl
```

The model learns patterns like: *"high bytes + suspicious port + high severity = malicious"*.

---

### `python run.py --mode pipeline`

The system starts, two background threads launch:

```
2026-05-11 18:54:51 [INFO] Pipeline ready. Logs -> data/logs
2026-05-11 18:54:51 [INFO] Starting Real-Time Forensics Pipeline...
2026-05-11 18:54:51 [INFO] Tailing Zeek log: data/logs/zeek_offline/conn.log
2026-05-11 18:54:51 [INFO] Tailing Suricata EVE: data/logs/suricata_offline/eve.json
```

Every 50 events a stats line prints:

```
2026-05-11 18:54:53 [INFO]  [STATS] Processed 50 events | benign=48 suspicious=2 malicious=0
2026-05-11 18:54:55 [INFO]  [STATS] Processed 100 events | benign=95 suspicious=4 malicious=1
```

When something malicious is found:

```
2026-05-11 18:54:56 [WARNING] [MALICIOUS] 192.168.1.100:54321 -> 10.0.0.1:4444
                               sig=ET TROJAN Generic  conf=0.86
                               Evidence: High IDS severity | Anomalous high byte transfer |
                               Suspicious destination port commonly used by Trojans
```

On shutdown (Ctrl+C):

```
2026-05-11 18:55:10 [INFO] Pipeline stopped.
                           Final counts: total=191 benign=185 suspicious=5 malicious=1
```

---

## 7. File-by-File Code Breakdown

---

### `run.py` — The Launcher

The single entry point. Accepts a `--mode` argument and routes to the right component.

```python
import argparse
import sys
import os
```
Standard library imports. `argparse` parses command-line arguments. `sys` and `os` for paths.

```python
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
```
Adds the project root to Python's import search path so `pipeline`, `ml`, etc. can be imported regardless of where you run the script from.

```python
def run_pipeline():
    from pipeline.main import RealTimePipeline
    RealTimePipeline().start()
```
Imports and starts the real-time pipeline. Imported inside the function so it only loads when needed.

```python
def run_train(dataset: str):
    from ml.train_model import train
    train(dataset_file=dataset, dataset_dir=None)
```
Calls the training function directly, passing the CSV dataset path.

```python
def run_pcap(pcap_path: str):
    from pipeline.ingest_wireshark import ingest_wireshark
    from pipeline.output_manager import OutputManager
    out = OutputManager("data/logs")
    count = ingest_wireshark(pcap_path, out)
```
Creates an output manager (writes to disk), then runs tshark on the PCAP file and processes every packet through the pipeline.

```python
parser = argparse.ArgumentParser(description="DLDS IDS Launcher")
parser.add_argument("--mode", choices=["pipeline", "engine", "train", "pcap"], default="pipeline")
parser.add_argument("--dataset", default="detection-engine/dataset.csv")
parser.add_argument("--pcap", default="")
args = parser.parse_args()
```
Defines the four modes. `--dataset` defaults to the included dataset so training works out of the box. `--pcap` is only required when mode is `pcap`.

---

### `pipeline/main.py` — The Real-Time Pipeline

The heart of the system. Runs two threads that continuously read logs and classify every event.

```python
import os, sys, time, threading, logging
```
`threading` runs Zeek and Suricata readers in parallel. `time` drives the main loop. `logging` handles all console output.

```python
from pipeline.ingest_zeek     import tail_zeek_json
from pipeline.ingest_suricata import tail_suricata_eve
from pipeline.normalizer      import normalize_event
from pipeline.correlator      import Correlator
from pipeline.inference       import MLEngine
from pipeline.output_manager  import OutputManager
```
Imports each specialist module. Every module has one job:
- `tail_zeek_json` — reads Zeek logs line by line, forever
- `tail_suricata_eve` — reads Suricata logs line by line, forever
- `normalize_event` — converts raw log into unified dictionary
- `Correlator` — links Suricata alerts to Zeek flow data
- `MLEngine` — wraps the trained model
- `OutputManager` — writes to JSON and CSV

```python
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
    force=True,
)
```
Sets up logging to print to stdout with timestamps. `force=True` overrides any logging already configured by imported libraries. `sys.stdout` ensures output is not buffered.

```python
ZEEK_LOG      = os.getenv("ZEEK_LOG_PATH",     "data/logs/zeek_offline/conn.log")
SURICATA_LOG  = os.getenv("SURICATA_LOG_PATH", "data/logs/suricata_offline/eve.json")
LOCAL_LOG_DIR = os.getenv("LOCAL_LOG_DIR",     "data/logs")
```
Log paths are read from environment variables. If not set, sensible defaults are used. Change these in `.env` to point to live Zeek/Suricata logs.

```python
class RealTimePipeline:
    def __init__(self):
        self.correlator = Correlator(time_window_seconds=30)
```
Creates a correlator with a 30-second memory window. Events older than 30 seconds are evicted from the cache to prevent memory growth.

```python
        self.ml_engine  = MLEngine()
        self.output     = OutputManager(LOCAL_LOG_DIR)
```
Loads the trained model from disk. Creates the output manager pointed at the log directory.

```python
        self._counts = {"benign": 0, "suspicious": 0, "malicious": 0, "unscored": 0}
        self._total  = 0
```
Running counters for the stats summary printed every 50 events.

```python
        if not self.ml_engine.is_loaded:
            logging.warning("AI model not found — run: python run.py --mode train")
```
Warns the user immediately if training was never done, before any events come in.

```python
    def process_event(self, event: dict):
        enriched = self.ml_engine.classify(event)
        self.output.write_event(enriched)
```
Every event passes through here. `classify` adds `ml_label`, `ml_confidence`, and `evidence_summary` fields to the dictionary. `write_event` appends it to the JSON and CSV files.

```python
        label = enriched.get("ml_label", "unscored")
        self._counts[label] = self._counts.get(label, 0) + 1
        self._total += 1
```
Increments the appropriate counter and the total.

```python
        src = f"{enriched.get('src_ip','?')}:{enriched.get('src_port','?')}"
        dst = f"{enriched.get('dst_ip','?')}:{enriched.get('dst_port','?')}"
        sig = enriched.get("alert_signature", "") or enriched.get("sensor", "")
```
Builds human-readable source/destination strings and finds the best available signature label for the log line.

```python
        if label == "malicious":
            logging.warning("[MALICIOUS] %s -> %s  sig=%s  conf=%.2f  | %s", ...)
        elif label == "suspicious":
            logging.info("[SUSPICIOUS] %s -> %s  sig=%s  conf=%.2f", ...)
        elif self._total % 50 == 0:
            logging.info("[STATS] Processed %d events | ...", ...)
```
Three-tier output: malicious events get a WARNING (visible even in quiet configs), suspicious events get INFO, and every 50th benign event prints a progress line so you know the system is alive.

```python
    def _consume_zeek(self):
        for raw in tail_zeek_json(ZEEK_LOG):
            normalized = normalize_event("zeek", raw)
            self.correlator.add_zeek_event(normalized)
            self.process_event(normalized)
```
Infinite loop — reads the next Zeek log line, normalizes it, stores it in the correlator's memory (so Suricata can look it up later), then classifies it.

```python
    def _consume_suricata(self):
        for raw in tail_suricata_eve(SURICATA_LOG):
            normalized = normalize_event("suricata", raw)
            correlated = self.correlator.correlate_suricata_alert(normalized)
            self.process_event(correlated)
```
Same as Zeek but the extra step `correlate_suricata_alert` looks up whether Zeek already saw this connection and merges in the byte/duration data.

```python
    def start(self):
        threads = [
            threading.Thread(target=self._consume_zeek,     daemon=True, name="zeek"),
            threading.Thread(target=self._consume_suricata, daemon=True, name="suricata"),
        ]
        for t in threads:
            t.start()
```
Launches both readers as daemon threads. `daemon=True` means they automatically die when the main program exits — no hanging processes.

```python
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            logging.info("Pipeline stopped. Final counts: ...")
```
The main thread does nothing except sleep and wait for Ctrl+C. On exit it prints the final summary of how many events were processed.

---

### `pipeline/normalizer.py` — The Event Schema

Every sensor produces a different JSON format. This file translates all of them into one consistent dictionary.

```python
def normalize_event(sensor: str, raw_event: dict) -> dict:
```
Takes the sensor name (`"zeek"`, `"suricata"`, `"wireshark"`) and the raw dictionary parsed from the log line.

```python
    normalized = {
        "timestamp": "",  "sensor": sensor,  "flow_id": "",
        "src_ip": "",     "dst_ip": "",
        "src_port": 0,    "dst_port": 0,
        "protocol": "",   "bytes_sent": 0,   "bytes_received": 0,
        "duration": 0.0,  "connection_state": "",
        "alert_signature": "", "alert_category": "",
        "severity": 0,
        "ml_label": "unscored", "ml_confidence": 0.0, "evidence_summary": "",
        "process_name": "", "pid": 0, "uid": 0, "gid": 0, "file_path": "",
    }
```
The blank template. Every event starts with all fields set to zero/empty. The sensor-specific block below fills in what it knows. This guarantees the ML engine always receives every field — never a `KeyError`.

```python
    if sensor == "zeek":
        normalized["src_ip"]  = raw_event.get("id.orig_h", "")
        normalized["dst_ip"]  = raw_event.get("id.resp_h", "")
        normalized["src_port"] = raw_event.get("id.orig_p", 0)
        normalized["dst_port"] = raw_event.get("id.resp_p", 0)
        normalized["bytes_sent"]     = raw_event.get("orig_bytes", 0)
        normalized["bytes_received"] = raw_event.get("resp_bytes", 0)
        normalized["duration"]       = raw_event.get("duration", 0.0)
        normalized["connection_state"] = raw_event.get("conn_state", "")
```
Zeek uses field names like `id.orig_h` (originator host) and `id.resp_h` (responder host). These are mapped to the plain `src_ip` / `dst_ip` names the rest of the pipeline understands.

```python
    elif sensor == "suricata":
        normalized["dst_ip"] = raw_event.get("dest_ip", "")  # Suricata says dest_ip not dst_ip
        alert = raw_event.get("alert", {})
        normalized["alert_signature"] = alert.get("signature", event_type)
        normalized["severity"]        = alert.get("severity", 0)
        flow = raw_event.get("flow", {})
        if isinstance(flow, dict):
            normalized["bytes_sent"] = int(flow.get("bytes_toserver", 0) or 0)
        dns = raw_event.get("dns", {})
        if isinstance(dns, dict):
            normalized["dns_query"] = dns.get("rrname", "")
        tls = raw_event.get("tls", {})
        if isinstance(tls, dict):
            normalized["tls_sni"] = tls.get("sni", "")
```
Suricata nests its data differently. Alert details are inside an `"alert"` sub-dictionary. Flow bytes are inside a `"flow"` sub-dictionary. DNS and TLS names are nested too. This block unpacks all of that into flat fields.

```python
    elif sensor == "wireshark":
        normalized["src_ip"]   = raw_event.get("ip.src", "")
        normalized["dst_ip"]   = raw_event.get("ip.dst", "")
        normalized["src_port"] = int(raw_event.get("tshark_src_port", 0))
        normalized["protocol"] = raw_event.get("frame.protocols", "unknown")
        normalized["bytes_sent"] = int(raw_event.get("frame.len", 0))
```
tshark outputs fields like `ip.src` and `frame.len`. These are mapped to the standard names. Port fields were pre-processed from `tcp.srcport` / `udp.srcport` into a single `tshark_src_port` field by `ingest_wireshark.py`.

```python
    return normalized
```
Returns the fully populated standard dictionary. From this point on, every part of the pipeline is sensor-agnostic.

---

### `pipeline/correlator.py` — The Event Correlator

Zeek gives you rich flow data (bytes, duration, state). Suricata gives you attack signatures. This module combines them.

```python
class Correlator:
    def __init__(self, time_window_seconds=10):
        self.time_window = time_window_seconds
        self.zeek_cache = {}
```
The cache is a dictionary keyed by `(src_ip, dst_ip, src_port, dst_port)` — the four-tuple that uniquely identifies a network flow. The window of 10 seconds means only recent Zeek events are kept (30 seconds in the pipeline).

```python
    def clean_cache(self):
        current_time = time.time()
        keys_to_delete = []
        for key, event in self.zeek_cache.items():
            if current_time - event.get("_ingest_time", current_time) > self.time_window:
                keys_to_delete.append(key)
        for key in keys_to_delete:
            del self.zeek_cache[key]
```
Iterates the cache and collects expired keys, then deletes them. Done in two steps (collect then delete) because you cannot modify a dictionary while iterating it in Python.

```python
    def add_zeek_event(self, normalized_event: dict):
        self.clean_cache()
        normalized_event["_ingest_time"] = time.time()
        key = (normalized_event["src_ip"], normalized_event["dst_ip"],
               normalized_event["src_port"], normalized_event["dst_port"])
        self.zeek_cache[key] = normalized_event
```
Stores each Zeek event. `_ingest_time` stamps the event with the current clock so `clean_cache` can expire it later. If the same flow appears twice, the newer entry overwrites the older one.

```python
    def correlate_suricata_alert(self, normalized_alert: dict) -> dict:
        self.clean_cache()
        key = (normalized_alert["src_ip"], normalized_alert["dst_ip"],
               normalized_alert["src_port"], normalized_alert["dst_port"])
        if key in self.zeek_cache:
            zeek_event = self.zeek_cache[key]
            normalized_alert["bytes_sent"]        = zeek_event.get("bytes_sent", 0)
            normalized_alert["bytes_received"]    = zeek_event.get("bytes_received", 0)
            normalized_alert["duration"]          = zeek_event.get("duration", 0.0)
            normalized_alert["connection_state"]  = zeek_event.get("connection_state", "")
        return normalized_alert
```
Looks up the same four-tuple in the Zeek cache. If found, copies the byte counts, duration, and connection state into the Suricata alert. This means the ML model gets richer data — it sees both the IDS signature *and* exactly how many bytes were transferred and for how long.

---

### `pipeline/inference.py` — The AI Classifier

Wraps the trained Random Forest model and adds human-readable explanations.

```python
class MLEngine:
    def __init__(self, model_path="ml/models/rf_model.pkl"):
        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        abs_model_path = os.path.join(base_dir, model_path)
```
Resolves the model path relative to the project root, not the current working directory. This makes it work regardless of where you launch the script from.

```python
        if os.path.exists(abs_model_path):
            data = joblib.load(abs_model_path)
            self.model        = data['model']         # the RandomForestClassifier
            self.features     = data['features']      # list of 11 feature names
            self.proto_encoder = data['proto_encoder'] # encodes "tcp" -> 2, "udp" -> 1, etc.
            self.flag_encoder  = data['flag_encoder']  # encodes TCP flags string -> int
            self.is_loaded = True
        else:
            self.model     = None
            self.is_loaded = False
```
The model bundle is a dictionary saved by `train_model.py` containing not just the model but also the encoders that were fitted on the training data. These must be the same encoders used at prediction time or the encoding will be wrong.

```python
    def _safe_encode(self, encoder, val):
        val_str = str(val)
        if val_str in encoder.classes_:
            return encoder.transform([val_str])[0]
        return 0
```
If a protocol or flag value was never seen during training, return 0 instead of crashing. This handles live traffic that contains edge cases not in the training set.

```python
    def classify(self, event: dict) -> dict:
        if not self.is_loaded:
            event["ml_label"] = "unscored"
            event["ml_confidence"] = 0.0
            event["evidence_summary"] = "AI model not found. Run training script."
            return event
```
Graceful fallback. If the model file is missing, every event is labelled `unscored` instead of crashing the pipeline.

```python
        dns_pres  = 1 if str(event.get('dns_query',  '')).strip() != '' else 0
        http_pres = 1 if str(event.get('http_host',  '')).strip() != '' else 0
        tls_pres  = 1 if str(event.get('tls_sni',    '')).strip() != '' else 0
```
DNS, HTTP, and TLS fields are converted from text to presence flags (1 = present, 0 = absent). The model expects numbers, not strings.

```python
        proto_enc = self._safe_encode(self.proto_encoder, event.get('protocol', ''))
        flags_enc = self._safe_encode(self.flag_encoder,  event.get('tcp_flags', ''))
```
Protocol ("tcp", "udp", "icmp") and TCP flags are encoded to integers using the same encoders that were built during training.

```python
        X = [
            int(event.get("src_port")    or 0),   # source port number
            int(event.get("dst_port")    or 0),   # destination port number
            proto_enc,                             # protocol encoded as int
            int(event.get("bytes_sent")  or 0),   # total bytes from client
            float(event.get("duration")  or 0.0), # connection duration in seconds
            int(event.get("severity")    or 0),   # IDS severity score (0-3)
            int(event.get("frame_length") or event.get("bytes_sent") or 0), # packet size
            flags_enc,                             # TCP flags encoded as int
            dns_pres,                              # 1 if DNS query present
            http_pres,                             # 1 if HTTP host present
            tls_pres,                              # 1 if TLS SNI present
        ]
        X_df = pd.DataFrame([X], columns=self.features)
```
Assembles the 11 features the model was trained on into a single-row DataFrame. The column names must match exactly what was used during training.

```python
        probs      = self.model.predict_proba(X_df)[0]
        prediction = self.model.classes_[probs.argmax()]
        confidence = probs.max()
```
`predict_proba` returns three probabilities — one per class (benign, suspicious, malicious). `argmax()` picks the index with the highest probability. `classes_[index]` maps that back to the label string. `max()` is the confidence score.

```python
        event["ml_label"]      = prediction
        event["ml_confidence"] = round(float(confidence), 4)
```
Writes results back into the event dictionary so everything travels together through the pipeline.

```python
        reasons = []
        if prediction == "malicious":
            if int(event.get("severity") or 0) >= 2:
                reasons.append("High IDS severity")
            if int(event.get("bytes_sent") or 0) > 50000:
                reasons.append("Anomalous high byte transfer")
            if int(event.get("dst_port") or 0) in [4444, 1337]:
                reasons.append("Suspicious destination port commonly used by Trojans")
            event["evidence_summary"] = "AI identified Malicious behavior: " + " | ".join(reasons)
```
Explainability. After classification, the code checks which specific features triggered the alert and assembles a plain-English explanation. Port 4444 is the default Metasploit listener port. Port 1337 is a classic backdoor port.

---

### `ml/train_model.py` — The Model Trainer

Reads a CSV dataset, engineers features, trains a Random Forest, and saves a bundle to disk.

```python
def _normalize_label(v) -> str:
    text = str(v).strip().lower()
    if text in {"0", "benign", "normal"}:    return "benign"
    if text in {"1", "suspicious"}:          return "suspicious"
    if text in {"2", "malicious", "attack"}: return "malicious"
    malicious_keywords = ["dos", "ddos", "exploit", "backdoor", "shellcode", "bot", ...]
    if any(k in text for k in malicious_keywords): return "malicious"
    return "suspicious"
```
Different public datasets use different label names. CIC-IDS2017 uses "BENIGN" and attack names. UNSW-NB15 uses numeric categories. This function maps all of them to the three classes the model uses.

```python
def _build_features(df: pd.DataFrame) -> pd.DataFrame:
    out["src_port"]  = pd.to_numeric(_first_present(df, ["src_port","Source Port","sport",...]))
    out["dst_port"]  = pd.to_numeric(_first_present(df, ["dst_port","Destination Port",...]))
    out["bytes_sent"] = pd.to_numeric(_first_present(df, ["bytes_sent","orig_bytes",...]))
    out["duration"]  = pd.to_numeric(_first_present(df, ["duration","dur","Flow Duration",...]))
    out["severity"]  = pd.to_numeric(_first_present(df, ["severity","alert_severity",...]))
    out["protocol"]  = _first_present(df, ["protocol","proto",...]).str.lower()
    out["tcp_flags"] = _first_present(df, ["tcp_flags","Flags","flag","history"])
    out["dns_query_presence"]  = dns_col.str.strip().ne("").astype(int)
    out["http_host_presence"]  = http_col.str.strip().ne("").astype(int)
    out["tls_sni_presence"]    = tls_col.str.strip().ne("").astype(int)
```
Different dataset column naming conventions are handled via `_first_present`, which tries multiple candidate column names and returns the first one that exists. This makes the trainer work with CIC-IDS2017, UNSW-NB15, Zeek logs, and custom datasets without modification.

```python
    clf = RandomForestClassifier(
        n_estimators=300,         # 300 decision trees vote on each event
        random_state=42,          # fixed seed for reproducible results
        n_jobs=-1,                # use all CPU cores for training
        class_weight="balanced_subsample",  # prevents the model from ignoring rare attack classes
    )
    clf.fit(X_train, y_train)
```
`n_estimators=300` means 300 independent decision trees each vote on the label. The majority vote wins. `balanced_subsample` is critical for security datasets because attack traffic is far rarer than normal traffic — without this the model would learn to call everything benign.

```python
    bundle = {
        "model":         clf,
        "features":      feature_cols,
        "proto_encoder": proto_encoder,
        "flag_encoder":  flag_encoder,
        "model_version": "rf-prod-v2.0",
    }
    joblib.dump(bundle, MODEL_PATH)
```
All components needed at prediction time are saved together in one file. `joblib` is used instead of `pickle` because it is faster for large NumPy arrays. The encoders must be saved alongside the model — they were fitted on training data and must produce the same mapping at runtime.

```python
    metadata = {
        "accuracy": acc, "precision": prec, "recall": rec, "f1_score": f1,
        "label_distribution": y.value_counts().to_dict(),
        "rows": int(len(df_raw)),
        "trained_at": datetime.now(timezone.utc).isoformat(),
    }
    with open(META_PATH, "w") as f:
        json.dump(metadata, f, indent=2)
```
Saves a human-readable JSON file alongside the model recording exactly when it was trained, on how many rows, and what accuracy was achieved. Useful for tracking model versions over time.

---

## Quick Reference

| Command | What it does |
|---|---|
| `python run.py --mode train` | Train the AI model |
| `python run.py --mode pipeline` | Start real-time detection |
| `python run.py --mode pcap --pcap file.pcap` | Analyse a PCAP file |
| `python check.py` | Verify all components work |
| `docker compose -f docker-compose.elk.yml up -d` | Start ELK visualisation |

| URL | Service |
|---|---|
| http://127.0.0.1:5601 | Kibana dashboards |
| http://127.0.0.1:9200 | Elasticsearch API |

| File | Output |
|---|---|
| `data/logs/audit_events.json` | All classified events (JSON lines) |
| `data/logs/audit_events.csv` | Same events in spreadsheet format |
| `ml/models/rf_model.pkl` | Trained model bundle |
| `ml/models/model_metadata.json` | Training metrics |
