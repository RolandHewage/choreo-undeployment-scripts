#!/bin/bash

# APIM DB connection details
DB_HOST=""
DB_USER=""
DB_PASSWORD=""
DB_NAME="choreo_apim_db"

# Inputs
ORG="$1"
INPUT_CSV="$2"

# Working files
SQL_SCRIPT="identify_api_revisions.sql"
RESULTS_TMP="identify_results.tmp"
OUTPUT_CSV="revisions-$ORG-$(date -u +%Y%m%d-%H%M%SZ).csv"

# Extract unique component UUIDs from the input CSV
COMPONENT_IDS=$(awk -F',' 'NR>1 {gsub(/[\"\r]/,""); print $2}' "$INPUT_CSV" | sort -u | paste -sd, -)

# Create the SQL script
cat > "$SQL_SCRIPT" <<SQL
SET NOCOUNT ON;
DECLARE @ids NVARCHAR(MAX) = '$COMPONENT_IDS';

SELECT c.CHOREO_COMPONENT_UUID,
       a.ORGANIZATION,
       a.API_UUID,
       d.REVISION_UUID,
       d.NAME,
       ISNULL(d.VHOST, ''),
       CAST(d.DISPLAY_ON_DEVPORTAL AS INT)
FROM CHOREO_AM_API c
JOIN STRING_SPLIT(@ids, ',') s ON c.CHOREO_COMPONENT_UUID = s.value
JOIN AM_API a ON c.API_UUID = a.API_UUID
JOIN AM_DEPLOYMENT_REVISION_MAPPING d ON d.API_UUID = a.API_UUID;
SQL

# Execute the SQL script using sqlcmd
if sqlcmd -S "$DB_HOST" -U "$DB_USER" -P "$DB_PASSWORD" -d "$DB_NAME" \
    -i "$SQL_SCRIPT" -s "," -W -h -1 -b -o "$RESULTS_TMP"; then
  echo "Executed the script."
  rm "$SQL_SCRIPT"
else
  echo "Failed to execute. Please check the error message."
  exit 1
fi

# Build revisions-<org>.csv (actionable + skipped rows, single file)
echo "org,component,organizationId,apiId,revisionId,env,vhost,displayOnDevportal,status" > "$OUTPUT_CSV"

grep -E '^[a-fA-F0-9-]+,' "$RESULTS_TMP" | \
awk -F',' -v org="$ORG" -v src="$INPUT_CSV" '
  BEGIN {
    while ((getline l < src) > 0) {
      gsub(/[\"\r]/, "", l)
      split(l, f, ",")
      names[f[2]] = f[1]
    }
  }
  { print org "," names[$1] "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 ",planned" }
' >> "$OUTPUT_CSV"

# Append rows for components with no APIM API
comm -23 \
  <(echo "$COMPONENT_IDS" | tr ',' '\n' | sort) \
  <(grep -E '^[a-fA-F0-9-]+,' "$RESULTS_TMP" | cut -d',' -f1 | sort -u) \
| while read -r cid; do
  cname=$(awk -F',' -v c="$cid" 'NR>1 {gsub(/[\"\r]/,""); if ($2==c) {print $1; exit}}' "$INPUT_CSV")
  echo "$ORG,$cname,,,,,,,skipped-no-api" >> "$OUTPUT_CSV"
done

rm "$RESULTS_TMP"
echo "Wrote $OUTPUT_CSV"
