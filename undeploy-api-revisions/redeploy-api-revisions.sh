#!/bin/bash

# APIM Publisher connection details
APIM_URL=""          # e.g. https://localhost:9443
APIM_USER=""         # e.g. choreo_<ns>_apim_admin (choreo_dev_apim_admin / choreo_prod_apim_admin)
APIM_PASSWORD=""

# Inputs
INPUT_CSV="$1"       # undeploy-results-*.csv
SLEEP_SECONDS=2

ORG=$(awk -F',' 'NR==2 {gsub(/[\"\r]/,""); print $1; exit}' "$INPUT_CSV")
OUTPUT_CSV="redeploy-results-${ORG:-unknown}-$(date -u +%Y%m%d-%H%M%SZ).csv"
echo "org,component,organizationId,apiId,revisionId,env,vhost,displayOnDevportal,status,http_code" > "$OUTPUT_CSV"

n=$(awk -F',' '$9=="undeployed"' "$INPUT_CSV" | wc -l | tr -d ' ')
echo "Redeploying $n rows from $INPUT_CSV."
i=0

awk -F',' '$9=="undeployed"' "$INPUT_CSV" | while IFS=',' read -r org comp orgid apiid revid env vhost display _; do
  i=$((i+1))

  # deploy-revision requires a valid vhost for the target env. If the input
  # row has none (APIM DB stored NULL for some legacy / internal-only deploys),
  # fetch the live vhost from Publisher /deployments.
  if [ -z "$vhost" ]; then
    fetched=$(curl -ksS --max-time 30 -u "$APIM_USER:$APIM_PASSWORD" \
      "$APIM_URL/api/am/publisher/v2/apis/$apiid/deployments?organizationId=$orgid" \
      | jq -r --arg env "$env" --arg rev "$revid" \
        '.[] | select(.name==$env and .revisionUuid==$rev) | .vhost' 2>/dev/null | head -1)
    if [ -n "$fetched" ] && [ "$fetched" != "null" ]; then
      vhost="$fetched"
      echo "[$i/$n] vhost empty in CSV — fetched '$vhost' from Publisher"
    fi
  fi

  if [ "$display" = "1" ]; then dj=true; else dj=false; fi
  body=$(printf '[{"name":"%s","vhost":"%s","displayOnDevportal":%s}]' "$env" "$vhost" "$dj")
  url="$APIM_URL/api/am/publisher/v2/apis/$apiid/deploy-revision?revisionId=$revid&organizationId=$orgid"

  code=$(curl -ksS -o /dev/null -w "%{http_code}" --max-time 30 \
         -u "$APIM_USER:$APIM_PASSWORD" -X POST \
         -H 'Content-Type: application/json' -d "$body" "$url")

  if [[ $code =~ ^2 ]]; then result="redeployed"; else result="failed"; fi
  echo "[$i/$n] $result HTTP=$code $comp/$env"
  echo "$org,$comp,$orgid,$apiid,$revid,$env,$vhost,$display,$result,$code" >> "$OUTPUT_CSV"
  sleep "$SLEEP_SECONDS"
done

echo "Wrote $OUTPUT_CSV"
