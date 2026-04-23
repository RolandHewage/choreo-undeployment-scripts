# Component-list CSV normalizer

Normalizes Choreo component-list CSVs into a common format so downstream scripts
(e.g. APIM revision identify / undeploy) can consume them without format surprises.

## What it does

For each `*.csv` in the source directory, writes a normalized copy to the destination:

- Strips the UTF-8 BOM from the first line.
- Converts Windows line endings (CRLF) to Unix (LF).
- Fixes the header if the first column `component` is unquoted — makes it
  `"component","component_id","release_id"` uniformly across all files.

Source files are left untouched. Data rows are preserved exactly (including
original quoting). No rows are added, removed, or edited.

## Prerequisites

- `bash`, `sed`, `tr`, `awk` (standard on macOS and Linux).

## Usage

```bash
chmod +x normalize-component-csvs.sh
./normalize-component-csvs.sh <source-dir> <dest-dir>
```

Example:

```bash
./normalize-component-csvs.sh original normalized
```

Output:

```
Normalized: bijirademos-component-list.csv
Normalized: choreointegrationteam-component-list.csv
...
Done. Output in normalized
```

## Merging region-split files (optional)

Some orgs have two CSVs, one per DP region, e.g.:

- `wso2sa-component-list.csv` (US)
- `wso2sa-component-list-ne.csv` (EU)

After normalization, merge them into a single file with:

```bash
tail -n +2 <dest-dir>/wso2sa-component-list-ne.csv >> <dest-dir>/wso2sa-component-list.csv
rm <dest-dir>/wso2sa-component-list-ne.csv
```

The second file's header is skipped (`tail -n +2`); its data rows are appended
to the first. Repeat for any other region-split pair.

### Per-org merging vs per-region

The split in the source files reflects the **DP region** where each component's
pods ran. For downstream scripts that only touch **CP state** (e.g. APIM
revision undeployment), DP region is irrelevant — merging per-org is simpler.
That's the default here. Originals are preserved under `original/` so the
per-region info is never lost.

Note: which CP the script is run **against** depends on the org's home CP, not
the merged CSV. Orgs in this repo all live on US CP, so scripts run against US
CP. For orgs on EU CP, run the same scripts against the EU CP bastion.

## Verifying output

Quick sanity check that the normalized folder is uniform:

```bash
DST=<dest-dir>
for f in "$DST"/*.csv; do
  printf "%-45s %s\n" "$(basename $f)" "$(head -1 $f)"
done
```

All lines should show the same header: `"component","component_id","release_id"`.

## Layout

```
.
├── README.md                       # this file
├── normalize-component-csvs.sh     # the script
├── original/
│   └── sample-component-list.csv   # schema reference (committed)
└── normalized/
    └── sample-component-list.csv   # schema reference (committed)
```

Real per-org CSVs are gitignored — they carry production org metadata. Each
folder commits a `sample-component-list.csv` with placeholder UUIDs to show
the expected schema and to mark where real CSVs should land. When working on
a new CR, drop the real CSVs into `original/` and run the normalizer; the
output lands in `normalized/` locally and stays out of version control.
