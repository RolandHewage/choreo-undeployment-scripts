#!/bin/bash
# Normalizes Choreo component-list CSVs into a common format:
#   - strips UTF-8 BOM
#   - converts CRLF line endings to LF
#   - fixes partially-unquoted header to "component","component_id","release_id"
# Source files are left untouched; normalized copies are written to <dest-dir>.
#
# Usage: ./normalize-component-csvs.sh <source-dir> <dest-dir>

SRC="$1"
DST="$2"

if [ -z "$SRC" ] || [ -z "$DST" ]; then
  echo "usage: $0 <source-dir> <dest-dir>"
  exit 2
fi
[ -d "$SRC" ] || { echo "source dir not found: $SRC"; exit 1; }
mkdir -p "$DST"

for f in "$SRC"/*.csv; do
  [ -e "$f" ] || { echo "no CSVs in $SRC"; exit 1; }
  name=$(basename "$f")
  sed $'1s/^\xef\xbb\xbf//' "$f" \
    | tr -d '\r' \
    | awk 'NR==1 && $0 !~ /^"component"/ { sub(/^component,/, "\"component\",") } { print }' \
    > "$DST/$name"
  echo "Normalized: $name"
done

echo "Done. Output in $DST"
