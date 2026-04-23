# Undeploy APIM API revisions

Removes stale gateway-environment deployment entries from APIM for components
that were previously paused (see `../pause-components/`). Leaves the APIs and
revisions themselves intact — only the deployment binding is removed, so the
same revision can be redeployed if needed.

Driven off [#39191](https://github.com/wso2-enterprise/choreo/issues/39191).

## Scripts

| Script | What it does |
|---|---|
| `identify-api-revisions.sh` | Queries `choreo_apim_db` for all deployed revisions of APIs backing the given components; emits `revisions-<org>-<timestamp>.csv` for review. Read-only. |
| `undeploy-api-revisions.sh` | Reads the reviewed `revisions-<org>-<timestamp>.csv` and calls Publisher v2 `undeploy-revision` per row. Writes `undeploy-results-*.csv`. |
| `verify-undeploy-api-revisions.sh` | Reads `undeploy-results-*.csv` and confirms each `undeployed` row is actually gone from APIM (via Publisher v2 `deployments`). Writes `verify-undeploy-results-*.csv`. |
| `redeploy-api-revisions.sh` | Rolls back: reads `undeploy-results-*.csv` and replays each successfully-undeployed row via Publisher v2 `deploy-revision`. |
| `verify-redeploy-api-revisions.sh` | Reads `redeploy-results-*.csv` and confirms each `redeployed` row is actually live again in APIM. Writes `verify-redeploy-results-*.csv`. |

## Prerequisites

- Access to the CP bastion with `kubectl` configured for the target cluster.
- `bash`, `curl`, `awk`, `sed`, `jq`, `sqlcmd` (mssql-tools) on the bastion.
  (`jq` is used by `verify-undeploy-api-revisions.sh` to parse the Publisher response.)
- DB credentials for `choreo_apim_db` (read-only is sufficient for identify;
  read-only is also fine for undeploy — Stage 2 writes only go through
  Publisher v2 HTTP, not the DB).
- APIM admin user / password — retrievable from the cluster, see below.
- Normalized component-list CSVs at `../component-lists/normalized/` (run
  `../component-lists/normalize-component-csvs.sh` first if not yet normalized).

## Credentials

Use your existing **APIM DB** (host, port, database, user, password) and
**APIM admin** (username, password) credentials. The scripts expect them
filled in at the top of each file.

If you need to retrieve them from the cluster, the one-liners below work
against the DEV control plane. Set `NS=dev` or `NS=prod`.

### APIM DB — all values in one go

Dumps `url`, `username`, and the decoded password from the APIM pod's
`deployment.toml` + `secret-apim-db-*`:

```bash
NS=dev; POD=$(kubectl -n $NS-choreo-apim get pod -o name | grep choreo-apim-am-deployment | head -1); SECRET=$(kubectl -n $NS-choreo-apim get secret -o name | grep '^secret/secret-apim-db' | head -1 | cut -d/ -f2); echo "--- APIM DB connection ---"; kubectl -n $NS-choreo-apim exec $POD -- sh -c 'grep -A3 "^\[database.apim_db\]" /home/wso2carbon/wso2-config-volume/repository/conf/deployment.toml | grep -E "url|username"'; echo "password = \"$(kubectl -n $NS-choreo-apim get secret "$SECRET" -o jsonpath='{.data.CHOREO_APIM_DB_PASSWORD}' | base64 -d)\""
```

Expected output:

```
--- APIM DB connection ---
url = "jdbc:sqlserver://172.22.6.6:1433;database=choreo_apim_db;..."
username = "choreo_apim_db_user"
password = "<decoded password>"
```

Parse the URL for host (`172.22.6.6`), port (`1433`), and database
(`choreo_apim_db`).

For a read-only-user alternative (`choreo_apim_readonly_db_user`), use
`secret-garbage-collector-*` if that secret exists in your cluster.

### APIM admin password

```bash
NS=dev; SECRET=$(kubectl -n $NS-choreo-system get secret -o name | grep '^secret/secret-delete-manager' | head -1 | cut -d/ -f2); echo "$(kubectl -n $NS-choreo-system get secret "$SECRET" -o jsonpath='{.data.APIM_ADMIN_PASSWORD}' | base64 -d)"
```

### APIM admin username

Deterministic: `choreo_<ns>_apim_admin` (e.g. `choreo_dev_apim_admin`). Or
look up from the cluster:

```bash
NS=dev; CM=$(kubectl -n $NS-choreo-system get cm -o name | grep '^configmap/env-dp-delete-manager' | head -1 | cut -d/ -f2); echo "$(kubectl -n $NS-choreo-system get cm "$CM" -o jsonpath='{.data.APIM_ADMIN_USERNAME}')"
```

## Runbook

### 1. Fill in credentials

Edit the top of each script you're about to run:

- `identify-api-revisions.sh` → `DB_HOST`, `DB_USER`, `DB_PASSWORD`
  (and optionally `DB_NAME` — defaults to `choreo_apim_db`).
- `undeploy-api-revisions.sh` / `redeploy-api-revisions.sh` /
  `verify-undeploy-api-revisions.sh` / `verify-redeploy-api-revisions.sh` →
  `APIM_URL` (e.g. `https://localhost:9443`), `APIM_USER`, `APIM_PASSWORD`.

### 2. Identify (Stage 1 — read-only DB query, one run per org CSV)

No port-forward needed — this step hits the APIM DB directly. Confirm
reachability first if unsure: `nc -zv <DB_HOST> 1433`.

```bash
chmod +x identify-api-revisions.sh
./identify-api-revisions.sh <org> ../component-lists/normalized/<org>-component-list.csv
```

Each run produces `revisions-<org>-<timestamp>.csv` with columns:
`org, component, organizationId, apiId, revisionId, env, vhost, displayOnDevportal, status`.

`status` is `planned` for rows that have an APIM deployment, or
`skipped-no-api` for non-API components (webapps, schedules, manual-triggers).

See `sample-revisions.csv` for the expected format.

### 3. Review

Inspect each `revisions-<org>-<timestamp>.csv` and attach to the CR for
approver review before Stage 2.

### 4. Undeploy (Stage 2 — writes, one run per reviewed file)

Port-forward APIM Publisher (keep open through steps 4–6 if rollback may be needed):

```bash
kubectl port-forward -n dev-choreo-apim svc/choreo-am-service 9443:9443 &
```

```bash
chmod +x undeploy-api-revisions.sh
./undeploy-api-revisions.sh revisions-<org>-<timestamp>.csv
```

Each row triggers a Publisher v2 `undeploy-revision` call:

```
POST $APIM_URL/api/am/publisher/v2/apis/{apiId}/undeploy-revision?revisionId={revisionId}&organizationId={orgId}
Content-Type: application/json
Body: [{"name":"<env>","vhost":"<vhost>","displayOnDevportal":<bool>}]
```

Output: `undeploy-results-<org>-<timestamp>.csv` with the full row plus final
`status` (`undeployed` | `failed`) and `http_code`. Attach as the run artefact.
Default pacing is 2s between calls (change `SLEEP_SECONDS` at the top if needed).

### 5. Verify undeploy

```bash
chmod +x verify-undeploy-api-revisions.sh
./verify-undeploy-api-revisions.sh undeploy-results-<org>-<timestamp>.csv
```

Queries Publisher v2 `GET /apis/{apiId}/deployments` per row and checks that
the `(revisionId, env)` pair's `deployedTime` is `null` (APIM keeps the row
as history with `deployedTime=null` after undeploy).

Output: `verify-undeploy-results-<org>-<timestamp>.csv` with per-row
`verification`:
- `verified-undeployed` — tuple is gone from the live deployments. Expected.
- `still-deployed` — tuple is still live. Investigate and re-run step 4.
- `check-failed` — Publisher check returned non-2xx. Retry verify.

### 6. Rollback (if required)

```bash
chmod +x redeploy-api-revisions.sh verify-redeploy-api-revisions.sh
./redeploy-api-revisions.sh undeploy-results-<org>-<timestamp>.csv
./verify-redeploy-api-revisions.sh redeploy-results-<org>-<timestamp>.csv
```

Replays only the rows where Stage 2 reported `undeployed`. Calls Publisher v2
`deploy-revision` with the originally-captured tuple, then verifies each row
is live (`verified-redeployed`).

Output: `redeploy-results-*.csv`, `verify-redeploy-results-*.csv`.

Stop the Publisher port-forward when you're done:

```bash
pkill -f "port-forward.*choreo-am-service"
```

## Implementation notes

- **Auth**: basic auth with the global APIM admin user (same credential used
  by `garbage-collector`). OAuth2 would also work but is not used here.
- **Tenant scoping**: every Publisher call must include
  `organizationId=<orgUuid>` as a query parameter — Choreo's APIM rejects
  tenant-scoped calls without it (returns 500). The `organizationId` comes
  from `AM_API.ORGANIZATION` and is selected by the identify query.
- **DB lookup uses `STRING_SPLIT`** (MSSQL 2016+). The input component UUIDs
  are joined into one comma-separated string passed as a single `NVARCHAR(MAX)`
  parameter — avoids shell-constructed `IN (…)` lists and scales cleanly to
  any number of components.
- **Pacing**: 2 s between Publisher calls matches the interval used by
  `garbage-collector` to let APIM persist changes.
