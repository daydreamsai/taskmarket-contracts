#!/usr/bin/env bash
# Parse forge coverage summary output and enforce minimum coverage thresholds.
# Usage: bash scripts/check-coverage.sh <forge-coverage-output-file>
set -e

FORGE_OUTPUT="${1}"

LINE_THRESHOLD=90
BRANCH_THRESHOLD=70
FUNC_THRESHOLD=90

if [ -z "$FORGE_OUTPUT" ] || [ ! -f "$FORGE_OUTPUT" ]; then
    echo "error: forge coverage output file not found: ${FORGE_OUTPUT}"
    echo "usage: bash scripts/check-coverage.sh <forge-coverage-output-file>"
    exit 1
fi

# Forge summary table columns: | File | Lines | Statements | Branches | Functions |
TOTAL_LINE=$(grep "| Total" "$FORGE_OUTPUT")

if [ -z "$TOTAL_LINE" ]; then
    echo "error: could not find Total line in forge coverage output"
    exit 1
fi

LINE_PCT=$(echo "$TOTAL_LINE" | awk -F'|' '{gsub(/%.*/, "", $3); gsub(/ /, "", $3); print $3+0}')
BRANCH_PCT=$(echo "$TOTAL_LINE" | awk -F'|' '{gsub(/%.*/, "", $5); gsub(/ /, "", $5); print $5+0}')
FUNC_PCT=$(echo "$TOTAL_LINE" | awk -F'|' '{gsub(/%.*/, "", $6); gsub(/ /, "", $6); print $6+0}')

echo "Coverage: lines=${LINE_PCT}%  branches=${BRANCH_PCT}%  functions=${FUNC_PCT}%"
echo "Thresholds: lines>=${LINE_THRESHOLD}%  branches>=${BRANCH_THRESHOLD}%  functions>=${FUNC_THRESHOLD}%"

FAIL=0

if awk "BEGIN { exit ($LINE_PCT < $LINE_THRESHOLD) ? 0 : 1 }"; then
    echo "FAIL: line coverage ${LINE_PCT}% is below ${LINE_THRESHOLD}%"
    FAIL=1
fi

if awk "BEGIN { exit ($BRANCH_PCT < $BRANCH_THRESHOLD) ? 0 : 1 }"; then
    echo "FAIL: branch coverage ${BRANCH_PCT}% is below ${BRANCH_THRESHOLD}%"
    FAIL=1
fi

if awk "BEGIN { exit ($FUNC_PCT < $FUNC_THRESHOLD) ? 0 : 1 }"; then
    echo "FAIL: function coverage ${FUNC_PCT}% is below ${FUNC_THRESHOLD}%"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "All coverage thresholds passed"
else
    exit 1
fi
