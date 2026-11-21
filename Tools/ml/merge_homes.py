"""Merges test homes into one for auditing: Analysis/, Lyrics/ and Media/ files that the target
lacks are cloned in (APFS copy-on-write via `cp -c`), and media.json records are merged.

Usage: merge_homes.py TARGET SOURCE ... [--only ids.txt]
Never point TARGET at the owner's data folder; SOURCE may be read-only.
"""
import json
import os
import subprocess
import sys

args = sys.argv[1:]
only = None
if "--only" in args:
    index = args.index("--only")
    only = {line.strip() for line in open(args[index + 1]) if line.strip()}
    del args[index:index + 2]
target, sources = args[0], args[1:]
assert "Application Support" not in target, "refusing to write into the app's real data"

records = json.load(open(os.path.join(target, "media.json")))
added = {"Analysis": 0, "Lyrics": 0, "Media": 0}
for source in sources:
    their = json.load(open(os.path.join(source, "media.json")))
    for folder in ("Analysis", "Lyrics"):
        os.makedirs(os.path.join(target, folder), exist_ok=True)
        for name in os.listdir(os.path.join(source, folder)):
            video = name.rsplit(".", 1)[0]
            if only is not None and video not in only:
                continue
            destination = os.path.join(target, folder, name)
            if not os.path.exists(destination):
                subprocess.run(["cp", "-c", os.path.join(source, folder, name), destination], check=True)
                added[folder] += 1
    for video, record in their.items():
        if (only is not None and video not in only) or video in records:
            continue
        file = os.path.join(source, "Media", record["fileName"])
        if not os.path.exists(file):
            continue
        destination = os.path.join(target, "Media", record["fileName"])
        if not os.path.exists(destination):
            subprocess.run(["cp", "-c", file, destination], check=True)
        records[video] = record
        added["Media"] += 1
json.dump(records, open(os.path.join(target, "media.json"), "w"))
print("added", added, "records now", len(records))
