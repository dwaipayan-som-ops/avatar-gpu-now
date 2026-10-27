# avatar-gpu-now

One read-only command that shows every avatar GPU on Cloud Run right now, in one table:

```
Region                             GPU now GPU peak conn now conn peak GPUs    $/h ended/5m  alerts
---------------------------------------------------------------------------------------------------
NA us-central1 (Iowa)                   0%       1%        1         2    1   3.19        0  none
IN asia-southeast1 (Singapore)          2%      98%       84        85    1   3.82      140  connections nearly full since 27 Oct 09:12Z
---------------------------------------------------------------------------------------------------
All regions                                                               2   7.01   = about $168 a day at this rate
```

(example numbers)

| Column | Meaning |
| --- | --- |
| GPU now | busiest minute of the last 5, average of the instances |
| GPU peak | busiest minute in the last `HOURS` hours (default 24) |
| conn now / conn peak | open connections per instance (idle reads about 1) |
| GPUs, $/h | instances running now, and what they cost an hour (a guide) |
| ended/5m | connections that ended in the last 5 minutes |
| alerts | alert policies labelled `alert_set=avatar-gpu` that are open now |

## Set up once (Cloud Shell)

1. Upload `gpu-now.sh` (Cloud Shell: More, then Upload), or:

   ```bash
   curl -sSLO https://raw.githubusercontent.com/dwaipayan-som-ops/avatar-gpu-now/main/gpu-now.sh
   ```

2. Tell it which projects to read, in one line (the project list is not in this repo):

   ```bash
   echo 'NA=my-project:us-central1 IN=other-project:asia-southeast1' > ~/.avatar-gpu-now
   ```

   Each entry is `LABEL=PROJECT:LOCATION[:SERVICE|SERVICE]`; the service defaults to `flashhead-avatar`.

## Run

```bash
bash gpu-now.sh                  # every region in the line
HOURS=6 bash gpu-now.sh          # peaks over the last 6 hours
ONLY="IN AU" bash gpu-now.sh     # some regions, by label
watch -n 60 bash gpu-now.sh      # refresh every minute (Ctrl-C to stop)
```

## What it does and does not do

- Read-only. The only `gcloud` call is `auth print-access-token`; every Google API call is a `curl` GET to Cloud Monitoring. Nothing is created or changed.
- You need `roles/monitoring.viewer` (or more) on each project.
- If gcloud has lost its login in Cloud Shell, it stops and says so: restart Cloud Shell (More, then Restart) and click Authorize.
