# choreo-undeployment-scripts

Operational scripts for undeployment-related Change Requests against the Choreo
control plane. Run from the CP bastion.

## The undeployment lifecycle

Idle / retired Choreo components are taken out of service in two phases:

1. **Pause the component** — scale its DP workloads (pods) to zero via
   `dp-rudder`'s pause API. This stops compute but leaves APIM state intact.
2. **Undeploy its APIM API revisions** — remove the gateway-environment
   deployment entries in APIM so the stale routes are gone from the gateway.

Both steps are driven off the same per-org CSV (`component, component_id,
release_id`) supplied in the parent CR.

## Layout

```
.
├── README.md                         # this file
├── .gitignore                        # ignores real CSVs + per-run artefacts
├── component-lists/                  # canonical CSV inputs, shared by all flows
│   ├── README.md                     # csv schema + normalizer usage
│   ├── normalize-component-csvs.sh   # strips BOM/CRLF, unifies header
│   ├── original/                     # untouched source CSVs (gitignored)
│   │   └── sample-component-list.csv
│   └── normalized/                   # normalized CSVs (gitignored)
│       └── sample-component-list.csv
├── pause-components/                 # Phase 1: pause / resume DP workloads
│   ├── README.md
│   ├── pause-pods.sh                 # hits dp-rudder pause endpoint per release
│   ├── resume-pods.sh                # rollback — dp-rudder resume endpoint
│   ├── sample-pause-results.csv
│   └── sample-resume-results.csv
└── undeploy-api-revisions/           # Phase 2: undeploy APIM revisions (driving CR)
    ├── README.md
    ├── identify-api-revisions.sh     # DB lookup → revisions-<org>-<timestamp>.csv
    ├── undeploy-api-revisions.sh     # Publisher v2 undeploy per row
    ├── verify-undeploy-api-revisions.sh            # confirm each undeployed row is gone
    ├── redeploy-api-revisions.sh       # rollback — Publisher v2 deploy-revision
    ├── verify-redeploy-api-revisions.sh            # confirm each redeployed row is live
    ├── sample-revisions.csv
    ├── sample-undeploy-results.csv
    ├── sample-verify-undeploy-results.csv
    ├── sample-redeploy-results.csv
    └── sample-verify-redeploy-results.csv
```

Each subfolder's `README.md` contains the runbook for that phase.

## End-to-end runbook (one org)

`<ns>` below is `dev` or `prod`. All steps run from a host with `kubectl`
access to the org's home CP region (orgs in the driving CR are all US CP).
Two options for `kubectl` access:

- **CP bastion** — standard ops path. `kubectl` is pre-configured.
- **Local machine** — download the kubeconfig from Rancher (cluster page →
  "Download KubeConfig"), then:

  ```bash
  export KUBECONFIG=~/Downloads/<cluster>.yaml
  kubectl config get-contexts   # find the context name
  ```

  Every `kubectl` command in this runbook then works locally, including
  `kubectl port-forward`.

Port-forwards are long-running. Stop them when the step is complete:

- Foreground terminal → `Ctrl+C`.
- Background (`&`) → `kill %1` (substitute job number from `jobs`).
- By name → `pkill -f "port-forward.*<service>"` (e.g. `dp-rudder` or
  `choreo-am-service`).

### 1. Get the per-org CSV and normalize

Place the CSV(s) from the parent CR into `component-lists/original/`,
then normalize:

```bash
cd component-lists
./normalize-component-csvs.sh original normalized
```

See [`component-lists/README.md`](component-lists/README.md) for schema,
normalization details, and the optional region-merge step.

### 2. Credentials

You'll need two sets, filled in at the top of the relevant scripts:

- **APIM DB** (host, port, database, user, password) — used by
  `identify-api-revisions.sh`. Read-only access is sufficient.
- **APIM admin** (username, password) — used by `undeploy-api-revisions.sh`
  and `redeploy-api-revisions.sh`.

Use the credentials you already have. If you need to retrieve them from the
cluster, see the one-liners in
[`undeploy-api-revisions/README.md`](undeploy-api-revisions/README.md#credentials).

### 3. Phase 1 — pause DP workloads

Skip this step if the parent CR (e.g. #38276 / #38289 / #38582) already
completed the pause. Otherwise:

```bash
kubectl port-forward -n <ns>-choreo-system svc/dp-rudder 8080:80 &

cd pause-components
./pause-pods.sh ../component-lists/normalized/<org>-component-list.csv
```

No credentials to fill in — the script hits the port-forwarded rudder at
`http://localhost:8080` directly. See
[`pause-components/README.md`](pause-components/README.md) for details.

**Stop the port-forward when done:**

```bash
pkill -f "port-forward.*dp-rudder"
# verify (expect no output)
ps aux | grep "port-forward.*dp-rudder" | grep -v grep
```

### 4. Phase 2 — identify APIM revisions (read-only)

No port-forward needed — identify talks to the APIM DB directly (verify
reachability with `nc -zv <DB_HOST> 1433` first if unsure).

```bash
cd undeploy-api-revisions
# fill DB_* at top of identify-api-revisions.sh first, then:
./identify-api-revisions.sh <org> ../component-lists/normalized/<org>-component-list.csv
```

Produces `revisions-<org>-<timestamp>.csv` — the list of `(apiId, revisionId, env, vhost,
displayOnDevportal)` tuples planned for undeploy.

### 5. Review `revisions-<org>-<timestamp>.csv`

Inspect the file and share with approvers. Rows with `status=planned` will be
acted on in step 6; rows with `status=skipped-no-api` are non-API components
and won't be touched.

### 6. Phase 2 — undeploy the approved revisions

Port-forward APIM Publisher (keep open through step 8 if you may need rollback):

```bash
kubectl port-forward -n <ns>-choreo-apim svc/choreo-am-service 9443:9443 &
```

```bash
# fill APIM_URL / APIM_USER / APIM_PASSWORD at top of undeploy-api-revisions.sh first, then:
./undeploy-api-revisions.sh revisions-<org>-<timestamp>.csv
```

Produces `undeploy-results-<org>-<timestamp>.csv`. Attach to the CR as the run
artefact.

### 7. Verify

Run the verify script against the undeploy result:

```bash
# fill APIM_URL / APIM_USER / APIM_PASSWORD at top of verify-undeploy-api-revisions.sh first, then:
./verify-undeploy-api-revisions.sh undeploy-results-<org>-<timestamp>.csv
```

Produces `verify-undeploy-results-*.csv` with a per-row verification status:
- `verified-undeployed` — the tuple is gone from Publisher's `deployments`
  list. Expected.
- `still-deployed` — the tuple is still present. Investigate and re-run step 6
  for those rows.
- `check-failed` — the Publisher check itself returned non-2xx; retry verify.

### 8. Rollback (only if needed)

Full rollback is two steps — restore APIM deployments and resume DP workloads.

**8a. Redeploy the APIM revisions:**

```bash
./redeploy-api-revisions.sh undeploy-results-<org>-<timestamp>.csv
./verify-redeploy-api-revisions.sh redeploy-results-<org>-<timestamp>.csv
```

Replays only the rows that actually undeployed, using the original
`(name, vhost, displayOnDevportal)` tuple. `verified-redeployed` confirms
the binding is live in Publisher.

**8b. Resume DP workloads** (if pause was done in step 3):

```bash
kubectl port-forward -n <ns>-choreo-system svc/dp-rudder 8080:80 &

cd ../pause-components
./resume-pods.sh ../component-lists/normalized/<org>-component-list.csv

pkill -f "port-forward.*dp-rudder"
```

**Stop the APIM Publisher port-forward when steps 6–8 are complete:**

```bash
pkill -f "port-forward.*choreo-am-service"
# verify (expect no output)
ps aux | grep "port-forward.*choreo-am-service" | grep -v grep
```

## Related Change Requests

- [#38182](https://github.com/wso2-enterprise/choreo/issues/38182) — parent pause-pods procedure
- [#38276](https://github.com/wso2-enterprise/choreo/issues/38276),
  [#38289](https://github.com/wso2-enterprise/choreo/issues/38289),
  [#38582](https://github.com/wso2-enterprise/choreo/issues/38582) — idle-component pause CRs
- [#39191](https://github.com/wso2-enterprise/choreo/issues/39191) — APIM revision undeployment (this repo's driving CR)

## Conventions

- Scripts are self-contained bash — external dependencies: `bash`, `curl`,
  `jq`, `sqlcmd` (mssql-tools), and standard POSIX utilities (`awk`, `sed`,
  `grep`, `cut`, `sort`, `paste`, `comm`, `tr`, `tail`, `wc`).
- Credentials are shell variables at the top of each script — SRE fills them
  in before running. No env var machinery, no CLI flags for secrets.
- Every data-mutating run produces a timestamped result CSV as its audit
  artefact; attach to the CR.
- Rollback scripts consume a result CSV to reverse the operation.
