#!/bin/zsh
# Runs every AutoMix audit with one binary on one test home and writes the results to a folder.
# Usage: Tools/run_audits.sh BINARY METROLIST_HOME OUT_DIR
# Run from the repository root with the sandbox off.
set -u
binary=$1
export METROLIST_HOME=$2
out=$3
mkdir -p "$out"
"$binary" --analysisaudit Tools/groundtruth/silver Tools/groundtruth/groups.csv --verbose > "$out/analysis.txt" 2>&1
"$binary" --mixaudit --approved --out "$out/approved.tsv" > "$out/approved.txt" 2>&1
"$binary" --mixaudit Tools/groundtruth/groups.csv --pairs 25 --out "$out/groups.tsv" > "$out/groups.txt" 2>&1
# owner-mixes.tsv is no longer measured: the owner said on 2026-11-21 that those saved transitions
# came from accidental clicks.
"$binary" --mixaudit --pairs-file Tools/ml/data/common-pairs.tsv --out "$out/common.tsv" > "$out/common.txt" 2>&1
"$binary" --mixaudit --pairs-file Tools/ml/data/history-pairs.tsv --out "$out/history.tsv" > "$out/history.txt" 2>&1
echo done > "$out/DONE"
