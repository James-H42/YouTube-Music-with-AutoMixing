"""Collects public reference mixes for AutoMix testing (see docs/AUTOMIX_REFERENCE_MIXES.md).

Every request goes through curl, one at a time and slowly. Python's own HTTP client got cut-off
replies through the agent sandbox's proxy, and curl did not. Nothing here needs an account.

  reference_mixes.py spotify OUT.tsv NAME=PLAYLIST_ID ...      public playlists, in order (embed page)
  reference_mixes.py discogs OUTDIR m:MASTER | r:RELEASE ...   saves Discogs release JSON (CC0 data)
  reference_mixes.py discogs-tsv OUT.tsv RELEASE.json ...      tracklists of saved releases, in order
  reference_mixes.py mixesdb-count "Category:Name" ...         number of set pages per MixesDB category
  reference_mixes.py mixesdb OUTDIR "Category:Name" ...        every set's tracklist, OUTDIR/<Name>.jsonl
  reference_mixes.py sets [--top N] FILE.jsonl ...             recurring transitions, remix moves, mashups
  reference_mixes.py vocadb groups.csv SILVER_DIR GROUP ...    VocaDB community BPM against silver labels
  reference_mixes.py pairs SEQ.tsv GROUP KIND [--every N]      consecutive tracks as common-mixes rows
                                                               (GROUP "-": one group per playlist/album)
  reference_mixes.py resolve OUT.tsv --pairs P.tsv ... --logs QUERIES.txt ANALYZE_LOG.txt ...
                     [--overrides Tools/groundtruth/reference-overrides.tsv]
                                                               query pairs -> --mixaudit pairs file

Sources that refuse automated requests are not used: 1001Tracklists (HTTP 403) and WhoSampled
(Cloudflare check). Spotify transitions themselves are not public (Premium only); only the order is.
"""
import collections
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse

AGENT = "automix-research/1.0"


def fetch(url, pause=1.0, accept=None):
    """Body of a GET request, or None. Retries with growing waits."""
    command = ["curl", "-sS", "-m", "40", "-A", AGENT, "--compressed", "-w", "\n%{http_code}"]
    if accept:
        command += ["-H", f"Accept: {accept}"]
    for attempt in range(4):
        time.sleep(pause + attempt * 5)
        run = subprocess.run(command + [url], capture_output=True, text=True)
        body, _, code = run.stdout.rpartition("\n")
        if run.returncode == 0 and code == "200":
            return body
        if code == "404":
            return None
        print(f"# retry {url[:90]} curl={run.returncode} http={code}", file=sys.stderr)
    return None


def fetch_json(url, pause=1.0):
    body = fetch(url, pause, accept="application/json")
    try:
        return json.loads(body) if body else None
    except json.JSONDecodeError:
        return None


# Spotify: the public embed page carries the playlist's track list in __NEXT_DATA__.
def spotify(out_path, specs):
    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# curator\tplaylist\tposition\tartists\ttitle\tseconds\n")
        for spec in specs:
            name, playlist = spec.split("=", 1)
            html = fetch(f"https://open.spotify.com/embed/playlist/{playlist}", pause=1.5) or ""
            match = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
            if not match:
                print(f"{name}: no data", file=sys.stderr)
                continue
            entity = json.loads(match.group(1))["props"]["pageProps"]["state"]["data"]["entity"]
            tracks = entity.get("trackList", [])
            for i, t in enumerate(tracks, 1):
                fields = [name, playlist, str(i), t.get("subtitle", ""), t.get("title", ""), str(round(t.get("duration", 0) / 1000))]
                out.write("\t".join(f.replace("\t", " ") for f in fields) + "\n")
            print(f"{name}: {entity.get('name')!r}, {len(tracks)} tracks")


# Discogs: unauthenticated API, at most 25 requests a minute.
def discogs(outdir, refs):
    os.makedirs(outdir, exist_ok=True)
    for ref in refs:
        kind, number = ref.split(":")
        release = number
        if kind == "m":
            master = fetch_json(f"https://api.discogs.com/masters/{number}", pause=3) or {}
            release = str(master.get("main_release", ""))
        data = fetch_json(f"https://api.discogs.com/releases/{release}", pause=3)
        if not data:
            print(f"{ref}: not found", file=sys.stderr)
            continue
        with open(os.path.join(outdir, f"{release}.json"), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        print(f"{ref} -> {release}: {data.get('title')} ({data.get('year')}), {len(data.get('tracklist', []))} rows")


def discogs_tsv(out_path, paths):
    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# release\talbum\tyear\tmixed by\tposition\tartists\ttitle\tduration\n")
        for path in paths:
            d = json.load(open(path, encoding="utf-8"))
            mixers = sorted({c["name"] for c in d.get("extraartists", []) if c.get("role", "").startswith(("DJ Mix", "Mixed"))})
            album_artists = " & ".join(a["name"] for a in d.get("artists", []))
            for t in d.get("tracklist", []):
                if t.get("type_") != "track":
                    continue
                artists = " & ".join(re.sub(r" \(\d+\)$", "", a["name"]) for a in t.get("artists", [])) or album_artists
                fields = [str(d["id"]), d.get("title", ""), str(d.get("year", "")), ", ".join(mixers),
                          t.get("position", ""), artists, t.get("title", ""), t.get("duration", "")]
                out.write("\t".join(f.replace("\t", " ") for f in fields) + "\n")


# MixesDB: MediaWiki API; tracklists are "# Artist - Title [Label]" lines under "== Tracklist ==".
MIXESDB = "https://www.mixesdb.com/w/api.php?"


def mixesdb_call(**params):
    params["format"] = "json"
    return fetch_json(MIXESDB + urllib.parse.urlencode(params), pause=1.0) or {}


def mixesdb_tracklist(wikitext):
    tracks, inside = [], False
    for line in wikitext.splitlines():
        if line.startswith("=="):
            inside = "tracklist" in line.lower()
            continue
        if not inside or not line.startswith("#"):
            continue
        text = re.sub(r"^#\s*(\[[^\]]*\]\s*)?", "", line).strip().strip("'").strip()
        text = re.sub(r"\s*\[[^\]]*\]\s*$", "", text).strip("'").strip()
        if " - " in text:
            tracks.append(text)
    return tracks


def mixesdb_members(category):
    titles, more = [], {}
    while True:
        d = mixesdb_call(action="query", list="categorymembers", cmtitle=category, cmlimit=500, cmnamespace=0, **more)
        titles += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        if "continue" not in d:
            return titles
        more = {"cmcontinue": d["continue"]["cmcontinue"]}


def mixesdb(outdir, categories):
    os.makedirs(outdir, exist_ok=True)
    for category in categories:
        path = os.path.join(outdir, category.split(":", 1)[1].replace("/", "_") + ".jsonl")
        done = set()
        if os.path.exists(path):
            done = {json.loads(line)["title"] for line in open(path, encoding="utf-8")}
        with open(path, "a", encoding="utf-8") as out:
            for title in mixesdb_members(category):
                if title in done:
                    continue
                d = mixesdb_call(action="parse", page=title, prop="wikitext")
                if "parse" not in d:
                    print(f"# skipped {title}", file=sys.stderr)
                    continue
                tracks = mixesdb_tracklist(d["parse"]["wikitext"]["*"])
                out.write(json.dumps({"title": title, "tracks": tracks}, ensure_ascii=False) + "\n")
                out.flush()
        print(category, "->", path)


def mixesdb_count(categories):
    for category in categories:
        d = mixesdb_call(action="query", prop="categoryinfo", titles=category)
        for page in d.get("query", {}).get("pages", {}).values():
            print(f"{page['title']}\t{page.get('categoryinfo', {}).get('pages', 0)}")


# Set analysis.
UNKNOWN = re.compile(r"(^|\s)(\?|id)(\s|$)|unknown|untitled", re.I)


def normalise(track):
    t = track.lower().lstrip("+ ").strip()
    t = re.sub(r"\b(feat\.?|ft\.?|featuring)\b.*?(?= - |\(|$)", "", t)
    t = re.sub(r"[\"'’`]", "", t)
    return re.sub(r"\s+", " ", t).strip()


def base_title(track):
    title = track.split(" - ", 1)[1] if " - " in track else track
    return re.sub(r"\s+", " ", re.sub(r"\(.*?\)|\[.*?\]", "", title)).strip()


def is_version(track):
    return bool(re.search(r"\((?=[^)]*(remix|edit|rework|bootleg|flip|vip|mix\b|version|remake|cover|acapella|acappella|instrumental))", track, re.I))


def is_mashup(track):
    return bool(re.search(r"\bvs\.?\b| x |mash ?up", track, re.I))


def sets(paths, top=15, min_sets=2):
    for path in paths:
        played = []
        for line in open(path, encoding="utf-8"):
            record = json.loads(line)
            tracks = [normalise(t) for t in record["tracks"] if not UNKNOWN.search(t.split(" - ", 1)[-1])]
            if len(tracks) >= 3:
                played.append((record["title"], tracks))
        kept = []  # a rebroadcast shares over 60 % of its tracks with a set already kept
        for title, tracks in played:
            s = set(tracks)
            if not any(len(s & set(k)) > 0.6 * min(len(s), len(k)) for _, k in kept):
                kept.append((title, tracks))
        plays = collections.Counter(t for _, tracks in kept for t in set(tracks))
        transitions = collections.defaultdict(set)
        versions, mashups = [], collections.Counter()
        for title, tracks in kept:
            for a, b in zip(tracks, tracks[1:]):
                if a == b:
                    continue
                transitions[(a, b)].add(title[:10])
                if base_title(a) and base_title(a) == base_title(b) and (is_version(a) or is_version(b)):
                    versions.append((title[:10], a, b))
            mashups.update(t for t in tracks if is_mashup(t))
        recurring = sorted(((len(v), k) for k, v in transitions.items() if len(v) >= min_sets), reverse=True)
        name = os.path.basename(path).rsplit(".", 1)[0]
        print(f"\n## {name}: {len(played)} sets with tracklists, {len(kept)} without rebroadcasts, "
              f"{sum(len(t) for _, t in kept)} tracks, {len(transitions)} distinct transitions, {len(recurring)} recurring")
        print("most played:", "; ".join(f"{t} ×{n}" for t, n in plays.most_common(top)))
        for n, (a, b) in recurring[:top]:
            print(f"  recurring {n} sets: {a}  →  {b}")
        for when, a, b in versions[:top]:
            print(f"  version {when}: {a}  →  {b}")
        print(f"  mashups: {len(mashups)} distinct;", "; ".join(f"{t} ×{n}" for t, n in mashups.most_common(5)))


# VocaDB: community-entered BPM, looked up by the song's YouTube id.
def vocadb(groups_path, silver_dir, wanted):
    def ratio_name(reference, estimate):
        r = estimate / reference
        for name, f in (("same", 1), ("x2", 2), ("x1/2", 0.5), ("x3/2", 1.5), ("x2/3", 2 / 3), ("x4/3", 4 / 3), ("x3/4", 0.75)):
            if abs(r - f) / f < 0.03:
                return name
        return f"other ({r:.2f})"

    counts = collections.Counter()
    for line in open(groups_path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        video, group, title = line.rstrip("\n").split(",", 2)
        if group not in wanted:
            continue
        song = fetch_json(f"https://vocadb.net/api/songs/byPv?pvService=Youtube&pvId={video}", pause=1.0)
        if not song or not song.get("id"):
            counts["not on VocaDB"] += 1
            print(f"{video}\t{title[:50]}\tnot on VocaDB")
            continue
        details = fetch_json(f"https://vocadb.net/api/songs/{song['id']}/details", pause=1.0) or {}
        low, high = details.get("minMilliBpm"), details.get("maxMilliBpm")
        try:
            silver = json.load(open(os.path.join(silver_dir, f"{video}.json")))["bpm"]
        except (OSError, KeyError, ValueError):
            silver = None
        if not low:
            verdict = "no BPM on VocaDB"
        elif low != high:
            verdict = f"tempo range {low / 1000:g}-{high / 1000:g}"
        elif silver:
            verdict = ratio_name(low / 1000, silver)
        else:
            verdict = "no silver label"
        counts[verdict.split(" (")[0]] += 1
        print(f"{video}\t{title[:50]}\tVocaDB {song['id']}\t{(low or 0) / 1000:g}\tsilver {silver}\t{verdict}")
    print("#", dict(counts))


# Consecutive tracks of a sequence file (spotify or discogs-tsv output) as common-mixes rows.
def pairs(seq_path, group, kind, every=1):
    rows = [line.rstrip("\n").split("\t") for line in open(seq_path, encoding="utf-8") if not line.startswith("#")]
    is_discogs = len(rows[0]) >= 8 if rows else False
    by_list = collections.OrderedDict()
    for r in rows:
        name = r[1] if is_discogs else r[0]  # album title, or the playlist's curator
        artist, title = (r[5], r[6]) if is_discogs else (r[3].split(",")[0].strip(), r[4])
        position = r[4] if is_discogs else ""
        disc = re.split(r"[-.]", position)[0] if re.search(r"[-.]", position) else ""
        by_list.setdefault((name, disc), []).append(f"{artist} {title}")
    for (name, _), queries in by_list.items():
        label = name if group == "-" else group  # "-": one group per playlist or album
        for i, (a, b) in enumerate(zip(queries, queries[1:])):
            if i % every == 0:
                print(f"{label}\t{kind}\t{a}\t{b}")


def words(text):
    text = unicodedata.normalize("NFKC", text).lower().replace("'", "").replace("’", "")
    return set(re.findall(r"[a-z0-9]+|[぀-ヿ一-鿿]", text))


def plausible(query, resolved):
    """At least half of the query's words appear in the resolved "Title — Artist"."""
    asked = words(query)
    return not asked or len(asked & words(resolved)) >= 0.5 * len(asked)


# Query -> video id, from `Metrolist --analyze` output ("Title — Artist [id]" per resolved query,
# "query: could not fetch" or "Title: analysis failed" otherwise), in query order. Results that
# share too few words with the query are dropped when `strict`.
def resolved_ids(queries_path, log_path, strict=True):
    queries = [q for q in open(queries_path, encoding="utf-8").read().split("\n") if q]
    found, position = {}, 0
    for line in open(log_path, encoding="utf-8").read().split("\n"):
        if position >= len(queries):
            break
        if line.endswith(": could not fetch") or line.endswith("analysis failed"):
            position += 1
            continue
        match = re.search(r" — (.*) \[([A-Za-z0-9_-]{11})\]$", line)
        if match:
            title = line[: line.rfind(" [")]
            if not strict or plausible(queries[position], title):
                found[queries[position]] = (match.group(2), title)
            position += 1
    return found


def overrides(path):
    """Query -> video id, or None for "skip" (a wrong first search hit)."""
    result = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if line.startswith("#") or not line.strip():
                continue
            query, value = line.rstrip("\n").split("\t")[:2]
            result[query] = None if value == "skip" else value
    return result


def resolve(out_path, pair_paths, logs, override_path=None):
    """Writes a --mixaudit pairs file ("kind:group", idA, idB) from query pairs."""
    found = {}
    for queries_path, log_path in zip(logs[::2], logs[1::2]):
        found.update(resolved_ids(queries_path, log_path))
    for query, video in overrides(override_path).items():
        if video is None:
            found.pop(query, None)
        else:
            found[query] = (video, query)
    rows, missing = [], 0
    for path in pair_paths:
        for line in open(path, encoding="utf-8"):
            if line.startswith("#") or not line.strip():
                continue
            group, kind, a, b = line.rstrip("\n").split("\t")[:4]
            if a in found and b in found and found[a][0] != found[b][0]:
                rows.append(f"{kind}:{group}\t{found[a][0]}\t{found[b][0]}")
            else:
                missing += 1
    open(out_path, "w", encoding="utf-8").write("\n".join(rows) + "\n")
    print(f"{len(rows)} pairs resolved, {missing} not ({len(found)} songs found)")


if __name__ == "__main__":
    command, rest = sys.argv[1], sys.argv[2:]
    if command == "spotify":
        spotify(rest[0], rest[1:])
    elif command == "discogs":
        discogs(rest[0], rest[1:])
    elif command == "discogs-tsv":
        discogs_tsv(rest[0], rest[1:])
    elif command == "mixesdb":
        mixesdb(rest[0], rest[1:])
    elif command == "mixesdb-count":
        mixesdb_count(rest)
    elif command == "sets":
        top = 15
        if rest[:1] == ["--top"]:
            top, rest = int(rest[1]), rest[2:]
        sets(rest, top)
    elif command == "vocadb":
        vocadb(rest[0], rest[1], rest[2:])
    elif command == "pairs":
        every = int(rest[rest.index("--every") + 1]) if "--every" in rest else 1
        pairs(rest[0], rest[1], rest[2], every)
    elif command == "resolve":
        # resolve OUT.tsv --pairs P.tsv ... --logs queries.txt resolve.txt [...] [--overrides F]
        override = None
        if "--overrides" in rest:
            index = rest.index("--overrides")
            override = rest[index + 1]
            rest = rest[:index] + rest[index + 2:]
        cut = rest.index("--logs")
        resolve(rest[0], rest[rest.index("--pairs") + 1: cut], rest[cut + 1:], override)
    else:
        print(__doc__)
