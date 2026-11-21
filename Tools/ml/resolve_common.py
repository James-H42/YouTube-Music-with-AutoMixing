"""Turns Tools/groundtruth/common-mixes.tsv into a --mixaudit pairs file, using the output of
`Metrolist --analyze` run over data/common-queries.txt (one query per line, in that order).

Usage: python3 resolve_common.py common-mixes.tsv common-queries.txt common-resolve.txt OUT.tsv
"""
import re
import sys

mixes, queries_path, log_path, out_path = sys.argv[1:5]
queries = [q for q in open(queries_path, encoding="utf-8").read().split("\n") if q]
lines = open(log_path, encoding="utf-8").read().split("\n")
resolved = {}
titles = {}
position = 0
for line in lines:
    if position >= len(queries):
        break
    if line.endswith(": could not fetch"):
        position += 1
        continue
    match = re.search(r" — (.*) \[([A-Za-z0-9_-]{11})\]$", line)
    if match:
        resolved[queries[position]] = match.group(2)
        titles[queries[position]] = line[: line.rfind(" [")]
        position += 1
    elif line.endswith("analysis failed"):
        position += 1
rows = []
for line in open(mixes, encoding="utf-8"):
    if not line.strip() or line.startswith("#"):
        continue
    group, kind, a, b = line.rstrip("\n").split("\t")
    if a in resolved and b in resolved:
        rows.append(f"common:{kind}\t{resolved[a]}\t{resolved[b]}")
        print(f"{kind:13} {titles[a][:45]:45} -> {titles[b][:45]}")
    else:
        print(f"UNRESOLVED    {a} -> {b}")
open(out_path, "w").write("\n".join(rows) + "\n")
print(len(rows), "pairs")
