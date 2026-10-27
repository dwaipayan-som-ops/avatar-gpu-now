#!/usr/bin/env bash
# gpu-now.sh  (READ-ONLY): every avatar GPU on Cloud Run, right now, in one table.
#
# For each region you list it shows, from Cloud Monitoring:
#   GPU now     busiest minute of the last 5, average of the instances (%)
#   GPU peak    busiest minute in the last HOURS hours (default 24)
#   conn now    open connections per instance (p99 of max concurrent requests)
#   conn peak   most open connections in the last HOURS hours
#   GPUs        instances running now, and what they cost an hour
#   ended/5m    requests (connections) that ended in the last 5 minutes
#   alerts      alert policies labelled alert_set=avatar-gpu that are open now
#
# Which projects to read is NOT in this file. Give it one line, once:
#   LABEL=PROJECT:LOCATION[:SERVICE[|SERVICE...]] ...   (SERVICE defaults to flashhead-avatar)
# in the first of: $AVATAR_REGIONS, gpu-now.regions next to this script, ~/.avatar-gpu-now
#   echo 'NA=my-project:us-central1 IN=other-project:asia-southeast1' > ~/.avatar-gpu-now
#
# Read-only: the only gcloud call is print-access-token (names --project, ends
# with --quiet); every Google API call is a curl GET. You need
# roles/monitoring.viewer on each project. About 10 seconds.
#
#   bash gpu-now.sh                  # every region in the line
#   HOURS=6 bash gpu-now.sh          # peaks over the last 6 hours
#   ONLY="IN AU" bash gpu-now.sh     # some regions, by label
#   watch -n 60 bash gpu-now.sh      # refresh every minute (Ctrl-C to stop)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="${AVATAR_REGIONS:-}"
for f in "$HERE/gpu-now.regions" "$HOME/.avatar-gpu-now"; do
  if [[ -z "$LINE" && -f "$f" ]]; then LINE="$(grep -v '^[[:space:]]*#' "$f" | tr '\n' ' ')"; fi
done
W=$(mktemp -d)
chmod 700 "$W"
trap 'rm -rf "$W"' EXIT

cat > "$W/now.py" <<'PYEOF'
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import subprocess
import sys

W, LINE = sys.argv[1], sys.argv[2]
HOURS = max(1, min(168, int(os.environ.get("HOURS", "24"))))
ONLY = {x.lower() for x in os.environ.get("ONLY", "").split()}
ALERT_SET = os.environ.get("ALERT_SET", "avatar-gpu")
UTC = dt.timezone.utc

# --- signals (the same as monitoring/gpu-alerts.yaml) ---
SIGNALS = {
    "gpu_max5m": 'max_over_time((sum({"run.googleapis.com/container/gpu/utilizations_sum",{sel}}) / sum({"run.googleapis.com/container/gpu/utilizations_count",{sel}}))[5m:1m])',
    "gpu_now": 'sum({"run.googleapis.com/container/gpu/utilizations_sum",{sel}}) / sum({"run.googleapis.com/container/gpu/utilizations_count",{sel}})',
    "connections": 'histogram_quantile(0.99, sum by (le) (increase({"run.googleapis.com/container/max_request_concurrencies_bucket",{sel}}[5m])))',
    "instances": 'sum({"run.googleapis.com/container/instance_count",{sel}})',
    "sockets_per_5min": 'sum(increase({"run.googleapis.com/request_count",{sel}}[5m]))',
}
# --- end signals ---
CITY = {"us-central1": "Iowa", "us-east4": "Virginia", "us-west1": "Oregon", "europe-west1": "Belgium",
        "europe-west4": "Netherlands", "asia-southeast1": "Singapore", "asia-south1": "Mumbai",
        "australia-southeast1": "Sydney"}
# $/h for one instance with an RTX PRO 6000 + 20 vCPU + 80 GiB, no zonal redundancy (Cloud Run pricing,
# Oct 2026): $3.187 in Tier 1 regions, $3.824 in asia-southeast1 (Tier 2). A guide only: PRICE_PER_HOUR overrides.
TIER2 = {"asia-southeast1"}
ENTRY = re.compile(r"^([A-Za-z0-9_()-]+)=([a-z][a-z0-9-]{4,28}[a-z0-9]):([a-z]+-[a-z]+[0-9]+)(?::([A-Za-z0-9|_-]+))?$")


def regions_from(line):
    out, bad = {}, []
    for word in line.split():
        m = ENTRY.match(word)
        if not m:
            bad.append(word)
            continue
        label, project, location, svcs = m.groups()
        out[label] = {"label": label, "project": project, "location": location,
                      "city": CITY.get(location, location), "services": (svcs or "flashhead-avatar").split("|")}
    return out, bad


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "", f"timed out after {timeout}s", 124


def selector(r):
    svcs = r["services"]
    svc = f'service_name="{svcs[0]}"' if len(svcs) == 1 else f'service_name=~"{"|".join(svcs)}"'
    return f'monitored_resource="cloud_run_revision",{svc},location="{r["location"]}"'


def get(url, params):
    cmd = ["curl", "-sS", "-G", "--max-time", "60", "-H", f"@{W}/auth", "-w", "\n%{http_code}", url]
    for k, v in params:
        cmd += ["--data-urlencode", f"{k}={v}"]
    out, err, _ = run(cmd, 75)
    body, _, code = out.rpartition("\n")
    try:
        data = json.loads(body) if body.strip() else {}
    except ValueError:
        data = {}
    if code.strip() != "200":
        e = data.get("error") if isinstance(data, dict) else None
        msg = (e.get("message") if isinstance(e, dict) else None) or body or err
        return None, f"HTTP {code.strip() or '?'}: {' '.join(str(msg).split())[:200]}"
    return data, None


def value(project, query):
    data, err = get(f"https://monitoring.googleapis.com/v1/projects/{project}/location/global/prometheus/api/v1/query",
                    [("query", query)])
    if err:
        return None, err
    res = (data.get("data") or {}).get("result") or []
    vals = [float(x["value"][1]) for x in res if x.get("value")]
    vals = [v for v in vals if v == v]   # drop NaN
    return (max(vals) if vals else None), None


def region(key, r):
    sel = selector(r)
    q = {k: s.replace("{sel}", sel) for k, s in SIGNALS.items()}
    asks = {
        "gpu": q["gpu_max5m"],
        "gpu_peak": f'max_over_time(({q["gpu_now"]})[{HOURS}h:1m])',
        "conn": q["connections"],
        "conn_peak": f'max_over_time(({q["connections"]})[{HOURS}h:5m])',
        "gpus": q["instances"],
        "ended": q["sockets_per_5min"],
    }
    out, errs = {}, []
    for k, query in asks.items():
        v, err = value(r["project"], query)
        out[k] = v
        if err:
            errs.append(f"{k}: {err}")
    data, err = get(f"https://monitoring.googleapis.com/v3/projects/{r['project']}/alerts", [("pageSize", "200")])
    alerts = []
    for a in (data or {}).get("alerts", []) or []:
        pol = a.get("policy") or {}
        if (pol.get("userLabels") or {}).get("alert_set") == ALERT_SET and not a.get("closeTime"):
            name = pol.get("displayName", "?").split(": ", 1)[-1].rsplit(" - ", 1)[0]
            opened = a.get("openTime", "")[:19]
            when = dt.datetime.strptime(opened, "%Y-%m-%dT%H:%M:%S").strftime("%d %b %H:%MZ") if len(opened) == 19 else "?"
            alerts.append(f"{name} since {when}")
    if err:
        errs.append(f"alerts: {err}")
    out["alerts"] = alerts
    msgs = sorted({e.split(": ", 1)[1] for e in errs})
    out["errs"] = errs if len(msgs) > 1 else [f"{len(errs)} read(s) failed: {msgs[0]}"] if msgs else []
    return key, out


def pct(v):
    return "-" if v is None else f"{v * 100:.0f}%"


def num(v):
    return "-" if v is None else f"{v:.0f}"


REGIONS, bad = regions_from(LINE)
if bad or not REGIONS:
    print("STOP: tell gpu-now.sh which projects to read, in one line: LABEL=PROJECT:LOCATION[:SERVICE|SERVICE] ...")
    if bad:
        print("  not understood: " + " ".join(bad))
    print("  for example:  echo 'NA=my-project:us-central1 IN=other-project:asia-southeast1' > ~/.avatar-gpu-now")
    print("  (or AVATAR_REGIONS='...', or a gpu-now.regions file next to the script)")
    sys.exit(2)
regions = {k: r for k, r in REGIONS.items() if not ONLY or k.lower() in ONLY}
if not regions:
    sys.exit("no region matches ONLY=" + " ".join(sorted(ONLY)) + " (labels: " + " ".join(REGIONS) + ")")
first = next(iter(regions.values()))["project"]
tok, err, rc = run(["gcloud", "auth", "print-access-token", f"--project={first}", "--quiet"])
if rc or not tok.strip():
    print("STOP: gcloud cannot log in here. gcloud said:\n  " + " ".join(err.split())[:400])
    print("Fix: restart Cloud Shell (More > Restart) and click Authorize, then run this again.")
    sys.exit(2)
with open(f"{W}/auth", "w") as fh:
    fh.write(f"Authorization: Bearer {tok.strip()}\n")
os.chmod(f"{W}/auth", 0o600)

with cf.ThreadPoolExecutor(max_workers=6) as pool:
    got = dict(pool.map(lambda kv: region(*kv), regions.items()))

now = dt.datetime.now(UTC)
print(f"Avatar GPUs at {now:%d %b %H:%M} UTC ({(now + dt.timedelta(hours=5, minutes=30)):%H:%M} IST); peaks over the last {HOURS} h")
head = f"{'Region':<34} {'GPU now':>7} {'GPU peak':>8} {'conn now':>8} {'conn peak':>9} {'GPUs':>4} {'$/h':>6} {'ended/5m':>8}  alerts"
print(head)
print("-" * len(head))
total_gpus, total_cost = 0, 0.0
for key, r in regions.items():
    o = got[key]
    gpus = o["gpus"]
    rate = float(os.environ.get("PRICE_PER_HOUR") or (3.824 if r["location"] in TIER2 else 3.187))
    cost = (gpus or 0) * rate
    total_gpus += int(gpus or 0)
    total_cost += cost
    name = f"{r['label']} {r['location']} ({r['city']})"
    print(f"{name:<34} {pct(o['gpu']):>7} {pct(o['gpu_peak']):>8} {num(o['conn']):>8} {num(o['conn_peak']):>9} "
          f"{num(gpus):>4} {cost:>6.2f} {num(o['ended']):>8}  {'; '.join(o['alerts']) or 'none'}")
    for e in o["errs"]:
        print(f"{'':<34} !! {e}")
print("-" * len(head))
print(f"{'All regions':<34} {'':>7} {'':>8} {'':>8} {'':>9} {total_gpus:>4} {total_cost:>6.2f}   = about ${total_cost * 24:,.0f} a day at this rate")
print("conn = open connections per instance (idle reads ~1). '-' = no data (no instance running).")
print("Graphs: https://console.cloud.google.com/run/detail/<location>/<service>/metrics?project=<project>")
PYEOF

python3 "$W/now.py" "$W" "$LINE"
