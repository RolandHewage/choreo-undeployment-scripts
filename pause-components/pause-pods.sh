#!/usr/bin/env bash
# Usage:
#   DEBUG=1 ./pause-pods.sh apifirst-component_id.csv
#
# When DEBUG=1 it will print detailed info about each line and each curl.

set -euo pipefail

DEBUG="${DEBUG:-0}"

log_debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "[DEBUG] $*"
  fi
}

INPUT_FILE="${1:-apifirst-component_id.csv}"
OUTPUT_FILE="pause-results-$(date -u +%Y%m%d-%H%M%SZ).csv"
BASE_URL="http://localhost:8080/api/v1/choreo"

echo "Using input file: $INPUT_FILE"
echo "Writing results to: $OUTPUT_FILE"

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: Input file '$INPUT_FILE' does not exist" >&2
  exit 1
fi

echo "component_id,release_id,http_status" > "$OUTPUT_FILE"

line_no=0

# If your CSV has: component,component_id,release_id
# we read 3 columns and ignore the first
tail -n +2 "$INPUT_FILE" | while IFS=, read -r component component_id release_id; do
  line_no=$((line_no + 1))
  log_debug "Raw line $line_no: component='$component' component_id='$component_id' release_id='$release_id'"

  # Clean up quotes/whitespace/CRLF
  component_id="$(echo "$component_id" | tr -d '"' | tr -d '\r' | xargs)"
  release_id="$(echo "$release_id" | tr -d '"' | tr -d '\r' | xargs)"

  log_debug "Cleaned line $line_no: component_id='$component_id' release_id='$release_id'"

  # Skip empty lines
  if [[ -z "$component_id" || -z "$release_id" ]]; then
    log_debug "Skipping line $line_no: missing component_id or release_id"
    continue
  fi

  url="$BASE_URL/components/$component_id/releases/$release_id/pause"
  log_debug "Calling: curl -s -o /dev/null -w '%{http_code}' -X POST '$url'"

  # Capture HTTP status; avoid exiting on curl failure
  status="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" || echo "curl_error")"

  log_debug "Result line $line_no: status='$status' for component_id='$component_id', release_id='$release_id'"

  echo "$component_id,$release_id,$status" | tee -a "$OUTPUT_FILE"
done

echo "Done."

