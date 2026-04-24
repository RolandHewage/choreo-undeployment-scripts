#!/bin/bash

# APIM Publisher connection details
APIM_URL=""          # e.g. https://localhost:9443
APIM_USER=""         # e.g. choreo_<ns>_apim_admin (choreo_dev_apim_admin / choreo_prod_apim_admin)
APIM_PASSWORD=""

# Inputs
INPUT_CSV="$1"       # undeploy-results-*.csv
SLEEP_SECONDS=1

ORG=$(awk -F',' 'NR==2 {gsub(/[\"\r]/,""); print $1; exit}' "$INPUT_CSV")
OUTPUT_CSV="verify-undeploy-results-${ORG:-unknown}-$(date -u +%Y%m%d-%H%M%SZ).csv"
echo "org,component,organizationId,apiId,revisionId,env,undeploy_status,verification,http_code" > "$OUTPUT_CSV"

n=$(awk -F',' '$9=="undeployed"' "$INPUT_CSV" | wc -l | tr -d ' ')
echo "Verifying $n rows from $INPUT_CSV."
i=0

awk -F',' '$9=="undeployed"' "$INPUT_CSV" | while IFS=',' read -r org comp orgid apiid revid env vhost display status _; do
  i=$((i+1))
  url="$APIM_URL/api/am/publisher/v2/apis/$apiid/deployments?organizationId=$orgid"

  tmp=$(mktemp)
  code=$(curl -ksS -o "$tmp" -w "%{http_code}" --max-time 30 \
         -u "$APIM_USER:$APIM_PASSWORD" "$url")

  if [[ ! $code =~ ^2 ]]; then
    verification="check-failed"
  elif jq -e --arg rev "$revid" --arg env "$env" \
       '.[] | select(.revisionUuid==$rev and .name==$env and .deployedTime!=null)' \
       "$tmp" >/dev/null 2>&1; then
    # An entry with our (revid, env) AND deployedTime != null means the
    # binding is still live. deployedTime == null in the response is the
    # indicator that the revision has been undeployed (the record persists
    # as history).
    verification="still-deployed"
  else
    verification="verified-undeployed"
  fi
  rm -f "$tmp"

  echo "[$i/$n] $verification HTTP=$code $comp/$env"
  echo "$org,$comp,$orgid,$apiid,$revid,$env,$status,$verification,$code" >> "$OUTPUT_CSV"
  sleep "$SLEEP_SECONDS"
done

echo "Wrote $OUTPUT_CSV"
