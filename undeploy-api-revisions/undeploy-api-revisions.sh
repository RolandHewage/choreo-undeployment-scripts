#!/bin/bash

# APIM Publisher connection details
APIM_URL=""          # e.g. https://localhost:9443
APIM_USER=""         # e.g. choreo_<ns>_apim_admin (choreo_dev_apim_admin / choreo_prod_apim_admin)
APIM_PASSWORD=""

# Inputs
INPUT_CSV="$1"       # revisions-<org>-<timestamp>.csv from identify step
SLEEP_SECONDS=2

ORG=$(awk -F',' 'NR==2 {gsub(/[\"\r]/,""); print $1; exit}' "$INPUT_CSV")
OUTPUT_CSV="undeploy-results-${ORG:-unknown}-$(date -u +%Y%m%d-%H%M%SZ).csv"
echo "org,component,organizationId,apiId,revisionId,env,vhost,displayOnDevportal,status,http_code" > "$OUTPUT_CSV"

n=$(awk -F',' '$9=="planned"' "$INPUT_CSV" | wc -l | tr -d ' ')
echo "Undeploying $n rows from $INPUT_CSV."
i=0

awk -F',' '$9=="planned"' "$INPUT_CSV" | while IFS=',' read -r org comp orgid apiid revid env vhost display _; do
  i=$((i+1))

  if [ "$display" = "1" ]; then dj=true; else dj=false; fi
  body=$(printf '[{"name":"%s","vhost":"%s","displayOnDevportal":%s}]' "$env" "$vhost" "$dj")
  url="$APIM_URL/api/am/publisher/v2/apis/$apiid/undeploy-revision?revisionId=$revid&organizationId=$orgid"

  code=$(curl -ksS -o /dev/null -w "%{http_code}" --max-time 30 \
         -u "$APIM_USER:$APIM_PASSWORD" -X POST \
         -H 'Content-Type: application/json' -d "$body" "$url")

  if [[ $code =~ ^2 ]]; then result="undeployed"; else result="failed"; fi
  echo "[$i/$n] $result HTTP=$code $comp/$env"
  echo "$org,$comp,$orgid,$apiid,$revid,$env,$vhost,$display,$result,$code" >> "$OUTPUT_CSV"
  sleep "$SLEEP_SECONDS"
done

echo "Wrote $OUTPUT_CSV"
