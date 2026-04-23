# Pause components

Scales running component workloads (deployments) to zero via `dp-rudder`'s
pause API. Used for idle-component undeployments.

History: this is the same script attached to the parent change requests
(#38182, #38276, #38289, #38582) that shut down idle components across
internal / shared orgs.

## Prerequisites

- Access to the CP bastion with `kubectl` configured for the target cluster.
- A component list CSV for one org (see `../component-lists/` for normalized inputs).
  Expected columns: `component, component_id, release_id`. Only `component_id`
  and `release_id` are used; the `component` name column is ignored.
- Tools on bastion: `bash`, `curl`, `awk`, `tr`, `xargs`.

## Steps

### 1. Port-forward the rudder service

```bash
kubectl port-forward -n dev-choreo-system svc/dp-rudder 8080:80
```

(Substitute `dev-choreo-system` → `prod-choreo-system` for production.)
Leave this running in one terminal.

### 2. Run the script in another terminal

```bash
chmod +x pause-pods.sh
./pause-pods.sh ../component-lists/normalized/<org>-component-list.csv
```

For more verbose logging:

```bash
DEBUG=1 ./pause-pods.sh ../component-lists/normalized/<org>-component-list.csv
```

### 3. Share the output

The script writes `pause-results-<timestamp>.csv` with one row per processed
release and the HTTP status from rudder's pause endpoint. Attach this file to
the change request as the run artefact.

See `sample-pause-results.csv` for the expected output format.

## What the script does (per CSV row)

For each `(component_id, release_id)` in the input CSV, calls:

```
POST http://localhost:8080/api/v1/choreo/components/<component_id>/releases/<release_id>/pause
```

- `2xx` → release paused (DP workloads scaled to zero).
- Any other status → error recorded in the output CSV; run continues.

## Rollback — resume the paused components

`resume-pods.sh` is the mirror of `pause-pods.sh` — hits rudder's `/resume`
endpoint instead. Same input CSV, same usage pattern.

```bash
kubectl port-forward -n dev-choreo-system svc/dp-rudder 8080:80 &
./resume-pods.sh ../component-lists/normalized/<org>-component-list.csv
```

Produces `resume-results-<timestamp>.csv` with the HTTP status per release.

## Notes

- The pause endpoint only touches the DP side. It does **not** undeploy the
  corresponding APIM API revisions — for that, run the scripts under
  `../undeploy-api-revisions/` afterwards.
- Re-running against the same CSV is safe: already-paused releases return a
  2xx / idempotent response from rudder. Same holds for `resume-pods.sh`.
