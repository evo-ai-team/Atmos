"""Build the demo's offline routes from SF Public Works streets and SFMTA alignments.

Run with Python 3 and Node. Optionally pass a directory containing the two
downloaded source JSON files to reproduce the asset without network access.
"""
import heapq
import json
import math
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

DEMO = Path(__file__).resolve().parents[1]
SCALE = 1400 / 0.139
NORTH = math.asinh(math.tan(math.radians(37.7995)))


def source(file, dataset, fields, where=None):
    if len(sys.argv) > 1:
        return json.loads((Path(sys.argv[1]) / file).read_text(encoding="utf-8"))
    query = {"$select": fields, "$limit": 30000}
    if where:
        query["$where"] = where
    url = f"https://data.sfgov.org/resource/{dataset}.json?{urlencode(query)}"
    with urlopen(Request(url, headers={"User-Agent": "Atmos itinerary demo map builder"}), timeout=60) as res:
        return json.load(res)


def project(lon_lat):
    lon, lat = lon_lat[:2]
    return ((lon + 122.511) * SCALE,
            (NORTH - math.asinh(math.tan(math.radians(lat)))) * SCALE * 180 / math.pi)


def coordinates(points):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in points)


def shorten(points, tolerance=0.32):
    """Simplify a route while preserving turns at the scale of the basemap."""
    if len(points) < 3:
        return points
    (x, y), (ex, ey) = points[0], points[-1]
    dx, dy = ex - x, ey - y
    def deviation(p):
        t = max(0, min(1, ((p[0] - x)*dx + (p[1] - y)*dy) / (dx*dx + dy*dy or 1)))
        return math.dist(p, (x + t*dx, y + t*dy))
    cut = max(range(1, len(points)-1), key=lambda i: deviation(points[i]))
    if deviation(points[cut]) <= tolerance:
        return [points[0], points[-1]]
    return shorten(points[:cut+1], tolerance)[:-1] + shorten(points[cut:], tolerance)


streets = source("atmos-sf-streets.json", "3psu-pn9h",
                 "line,f_node_cnn,t_node_cnn,streetname,classcode,oneway,layer,active",
                 "within_box(line,37.810,-122.495,37.738,-122.382)")
bus_lines = source("atmos-sf-muni.json", "9exe-acju", "route_name,direction,shape")
walk, drive = defaultdict(list), defaultdict(list)
nodes, south_streets = {}, defaultdict(list)
for row in streets:
    if not row["active"] or row["layer"] not in {"STREETS", "STREETS_PEDESTRI"}:
        continue
    points = [project(p) for p in row["line"]["coordinates"]]
    a, b = row["f_node_cnn"], row["t_node_cnn"]
    nodes[a], nodes[b] = points[0], points[-1]
    length = sum(math.dist(start, end) for start, end in zip(points, points[1:]))
    walk[a].append((b, length, points))
    walk[b].append((a, length, points[::-1]))
    road = int(row["classcode"])
    if any(690 < x < 1250 and 548 < y < 705 for x, y in points):
        south_streets[road in (2,3)].append("M" + coordinates(shorten(points)))
    # General traffic examples avoid the transit-only downtown Market corridor.
    if row["layer"] != "STREETS" or road not in (2,3,4,5) or (row["streetname"] == "MARKET ST" and points[0][0] > 900):
        continue
    weight = length * {2:0.8, 3:0.85, 4:1, 5:1.15}[road]
    if row["oneway"] in ("B", "F"):
        drive[a].append((b, weight, points))
    if row["oneway"] in ("B", "T"):
        drive[b].append((a, weight, points[::-1]))


def street_path(graph, start, end, used=None):
    origin, dest = [min(graph, key=lambda n: math.dist(p, nodes[n])) for p in (start, end)]
    queue, costs, prev = [(0, origin)], {origin: 0}, {}
    while queue:
        cost, a = heapq.heappop(queue)
        if a == dest:
            break
        if cost != costs[a]:
            continue
        for b, weight, points in graph[a]:
            total = cost + weight * (1 + 0.9 * (used or {}).get((a,b), 0))
            if total < costs.get(b, math.inf):
                costs[b] = total
                prev[b] = (a, points)
                heapq.heappush(queue, (total, b))
    edges = []
    node = dest
    while node != origin:
        prior, points = prev[node]
        edges.append((prior, node, points))
        node = prior
    edges.reverse()
    shape = [start, nodes[origin]]
    for _, _, points in edges:
        shape.extend(points[1:])
    return shorten([*shape, end]), [(a,b) for a,b,_ in edges]


# Choose a representative single-line Muni corridor. Access links are approximate,
# and the display identifies the result as a demo route rather than a departure.
regular = {"1","5","6","8","9","12","14","14R","15","19","22","27","30","33","38R","45","49","F","J","K","N","T"}
alignments = [(r["route_name"], r["direction"], [project(p) for p in line])
              for r in bus_lines if r["route_name"] in regular
              for line in r["shape"]["coordinates"] if len(line) > 1]


def muni(start, end, required):
    best, score = None, math.inf
    # Snap to the named boarding points on the two morning routes.
    board = {"1": (-122.47214,37.78492), "38R": (-122.47233,37.78051)}
    boarding = project(board[required]) if required and start == stops["home"] else start
    for name, direction, points in alignments:
        if required and (name != required or direction != "I"):
            continue
        i = min(range(len(points)), key=lambda k: math.dist(boarding, points[k]))
        j = min(range(len(points)), key=lambda k: math.dist(end, points[k]))
        if j <= i:
            continue
        segment = points[i:j+1]
        length = sum(math.dist(p,q) for p,q in zip(segment, segment[1:]))
        estimate = length + 4 * (math.dist(start, points[i]) + math.dist(end, points[j]))
        if estimate < score:
            best, score = (name, segment), estimate
    if best is None:
        raise ValueError("Missing Muni alignment")
    name, line = best
    return {"line":name, "access":coordinates(street_path(walk, start, line[0])[0]),
            "ride":coordinates(shorten(line)), "exit":coordinates(street_path(walk, line[-1], end)[0])}


catalog = json.loads(subprocess.check_output([
    "node", "--input-type=module", "-e",
    "import {catalog as c} from './scenario.mjs'; console.log(JSON.stringify(c))"
], cwd=DEMO))
stops = {"home": project(catalog["originCoords"][::-1]), "loft": project(catalog["event"]["coords"][::-1])}
for slot in ("breakfast", "dinner", "nightlife"):
    stops.update({p["id"]: project(p["coords"][::-1]) for p in catalog[slot]})
pairs = [("home","loft"), ("home","breakfast"), ("breakfast","loft"),
         ("home","breakfast-battery"), ("breakfast-battery","loft")]
dinners = [d["id"] for d in catalog["dinner"] if d.get("available") is not False]
pairs += [("loft",d) for d in dinners]
pairs += [(d,n["id"]) for d in ["loft", *dinners] for n in catalog["nightlife"] if n.get("available") is not False]

lines = ["// Offline sample routes. Generated by scripts/build-route-shapes.py from SF Public Works and SFMTA.", "export const shapes = {"]
for a, b in pairs:
    start, end = stops[a], stops[b]
    walking, _ = street_path(walk, start, end)
    walk_shape = coordinates(walking)
    lines.append(f'  "{a}/{b}": {{')
    lines.append(f'    walk: "{walk_shape}",')
    if a != "breakfast-battery":  # The Battery Street stop always continues on foot.
        used, alternatives = defaultdict(int), []
        for attempt in range(6):
            shape, edges = street_path(drive, start, end, used)
            length = sum(math.dist(p,q) for p,q in zip(shape,shape[1:]))
            if attempt == 0:
                direct = length
                direct_edges = edges
            encoded = coordinates(shape)
            if length <= direct * 1.45 and encoded != walk_shape and encoded not in alternatives:
                alternatives.append(encoded)
                if len(alternatives) == 3:
                    break
            for edge in edges:
                used[edge] += 1
        if len(alternatives) < 3:
            # On short one-way legs most routes share the same approach. Find
            # nearby alternatives by bypassing individual blocks of the first drive.
            candidates = {}
            for edge in direct_edges:
                shape, edges = street_path(drive, start, end, {edge: 1000})
                length = sum(math.dist(p,q) for p,q in zip(shape,shape[1:]))
                encoded = coordinates(shape)
                if edge not in edges and encoded != walk_shape and encoded not in alternatives and length <= max(direct*1.45, direct+70):
                    candidates[encoded] = length
            alternatives.extend(sorted(candidates, key=candidates.get)[:3-len(alternatives)])
        lines.append("    drive: " + json.dumps(alternatives) + ",")
        required = "1" if "breakfast" in (a,b) else "38R" if a == "home" else None
        lines.append("    muni: " + json.dumps(muni(start, end, required)) + ",")
    lines.append("  },")
lines.append("};")
(DEMO / "public/route-shapes.js").write_text("\n".join(lines)+"\n", encoding="utf-8")
# The original northern basemap ends just above La Taqueria. Extend its street
# layer into the Mission only where the evening routes need it.
band = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="690 550 560 155">',
        '<title>Southern Mission District streets · SF Public Works</title>',
        '<rect x="690" y="550" width="560" height="155" fill="#edf0e9"/>']
for major in (False, True):
    band.append(f'<path d="{" ".join(south_streets[major])}" fill="none" stroke="#fcfcf8" stroke-width="{2.3 if major else 1.6}"/>')
(DEMO / "public/assets/sf-mission-streets.svg").write_text("\n".join([*band, "</svg>\n"]), encoding="utf-8")
