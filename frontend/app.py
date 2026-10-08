"""Minimal local web front end for the Mumbai PostGIS query library.

The SQL is not duplicated here. At start-up the files queries/NN_*.sql are
split into the blocks introduced by  \\echo '== <id> <title>'  and each block
is executed exactly as written. A few blocks accept parameters: specific
literals in their SQL (listed in QUERY_PARAMS) are swapped for bound
placeholders, and every value is validated first.

The page also has a live SQL console (POST /sql): one SELECT / WITH / EXPLAIN
statement typed by the user, checked by live_sql.check() before execution.

Everything runs as the read-only role mumbai_web (sql/04_web_readonly_role.sql)
inside a READ ONLY transaction that is always rolled back.
"""
import datetime
import decimal
import math
import os
import pathlib
import re
import struct
import time

import psycopg
from flask import Flask, jsonify, render_template, request

import live_sql
from samples import SAMPLES

ROOT = pathlib.Path(__file__).resolve().parent.parent
QUERY_DIR = ROOT / "queries"
MAX_ROWS = 500
LIVE_MAX_ROWS = 1000

# --------------------------------------------------------------------------
# Parameters: query id -> (defaults, [(literal in the SQL, replacement)]).
# Defaults equal the literals, so running with defaults reproduces results/*.txt.
# --------------------------------------------------------------------------
POINT_DEFAULTS = {"lat": 19.0760, "lon": 72.8777}
POINT = ("ST_MakePoint(72.8777, 19.0760)", "ST_MakePoint(%(lon)s, %(lat)s)")


def radius(metres):
    return (f"::geography, {metres})", "::geography, %(radius_m)s)")


QUERY_PARAMS = {
    "Q2.2": ({"ward": "K/W Ward"}, [("w.name = 'K/W Ward'", "w.name = %(ward)s")]),
    "Q2.3": ({"ward": "K/E Ward"}, [("w.name = 'K/E Ward'", "w.name = %(ward)s")]),
    "Q3.1": ({**POINT_DEFAULTS, "radius_m": 2000}, [POINT, radius(2000)]),
    "Q3.2": ({**POINT_DEFAULTS, "radius_m": 1000}, [POINT, radius(1000)]),
    "Q3.3": ({**POINT_DEFAULTS, "radius_m": 3000}, [POINT, radius(3000)]),
    "Q3.4": ({"station": "Andheri", "radius_m": 500},
             [("s.name = 'Andheri'", "s.name = %(station)s"), radius(500)]),
    "Q3.5": ({**POINT_DEFAULTS, "radius_m": 300}, [POINT, radius(300)]),
    "Q4.1": (dict(POINT_DEFAULTS), [POINT]),
    "Q4.2": (dict(POINT_DEFAULTS), [POINT]),
    "Q4.3": (dict(POINT_DEFAULTS), [POINT]),
    "Q4.4": (dict(POINT_DEFAULTS), [POINT]),
    "Q7.4": ({**POINT_DEFAULTS, "radius_m": 1000}, [POINT, radius(1000)]),
}

PARAM_LABELS = {
    "lat": "Latitude", "lon": "Longitude", "radius_m": "Radius (metres)",
    "ward": "BMC ward", "station": "Railway station",
}

HEADER = re.compile(r"^\\echo '== (\S+)\s+(.*)'\s*$")
TRANSACTION_CONTROL = re.compile(r"^(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION)\b", re.I)


def split_statements(text):
    """Split SQL on ';' outside single quotes and drop -- comments."""
    statements, current, in_quote, i = [], [], False, 0
    while i < len(text):
        ch = text[i]
        if in_quote:
            current.append(ch)
            if ch == "'":
                in_quote = False
        elif ch == "'":
            in_quote = True
            current.append(ch)
        elif text.startswith("--", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif ch == ";":
            statements.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1
    statements.append("".join(current).strip())
    return [s for s in statements if s]


def parse_query_file(path):
    """Return the query blocks of one queries/NN_*.sql file."""
    blocks, block = [], None
    for line in path.read_text().splitlines():
        match = HEADER.match(line)
        if match:
            block = {"id": match.group(1), "title": match.group(2),
                     "file": path.name, "lines": []}
            blocks.append(block)
        elif block is not None:
            block["lines"].append(line)

    for block in blocks:
        # Comment lines before the first statement describe the query.
        notes = []
        for line in block["lines"]:
            if line.startswith("--"):
                notes.append(line[2:].strip())
            elif line.strip():
                break
        block["description"] = " ".join(notes)

        # A sub-heading such as \echo '   (total count)' captions the next statement.
        statements, caption, buffer = [], None, []

        def flush():
            nonlocal caption
            for sql in split_statements("\n".join(buffer)):
                if TRANSACTION_CONTROL.match(sql):
                    continue  # the app manages the (read-only) transaction itself
                statements.append({"caption": caption, "sql": sql})
                caption = None
            buffer.clear()

        for line in block["lines"]:
            if line.startswith("\\echo"):
                flush()
                caption = line[len("\\echo"):].strip().strip("'").strip()
            else:
                buffer.append(line)
        flush()
        block["statements"] = statements
        del block["lines"]
    return blocks


def load_catalog():
    catalog = {}
    for path in sorted(QUERY_DIR.glob("[0-9][0-9]_*.sql")):
        for block in parse_query_file(path):
            defaults, replacements = QUERY_PARAMS.get(block["id"], ({}, []))
            full_sql = "\n".join(s["sql"] for s in block["statements"])
            missing = [lit for lit, _ in replacements if lit not in full_sql]
            if missing:
                # The SQL file changed: run it unparameterised rather than guess.
                app.logger.warning("%s: literal(s) %s not found; parameters disabled",
                                   block["id"], missing)
                defaults, replacements = {}, []
            block["defaults"] = defaults
            block["replacements"] = replacements
            catalog[block["id"]] = block
    return catalog


def connect():
    # Connection settings come from the libpq environment set by
    # scripts/run_web.sh (PGHOST, PGPORT, PGDATABASE, PGUSER=mumbai_web).
    return psycopg.connect(connect_timeout=5)


def load_choices():
    with connect() as conn:
        wards = [r[0] for r in conn.execute(
            "SELECT name FROM spatial_data.administrative_areas "
            "WHERE admin_level = '10' ORDER BY name")]
        stations = [r[0] for r in conn.execute(
            "SELECT DISTINCT name FROM spatial_data.railway_stations "
            "WHERE name IS NOT NULL ORDER BY name")]
    return {"ward": wards, "station": stations}


def validate(block, raw):
    """Return validated parameter values or raise ValueError."""
    values = {}
    for name in block["defaults"]:
        text = str(raw.get(name, "")).strip()
        if text == "":
            raise ValueError(f"{PARAM_LABELS[name]} is required.")
        if name in ("lat", "lon", "radius_m"):
            try:
                number = float(text)
            except ValueError:
                raise ValueError(f"{PARAM_LABELS[name]} must be a number.") from None
            low, high = {"lat": (-90, 90), "lon": (-180, 180), "radius_m": (0, 100000)}[name]
            if not math.isfinite(number) or not low <= number <= high:
                raise ValueError(f"{PARAM_LABELS[name]} must be between {low} and {high}.")
            values[name] = number
        else:
            if text not in CHOICES[name]:
                raise ValueError(f"Unknown {PARAM_LABELS[name]}: {text}")
            values[name] = text
    return values


GEOMETRY_TYPES = {1: "POINT", 2: "LINESTRING", 3: "POLYGON", 4: "MULTIPOINT",
                  5: "MULTILINESTRING", 6: "MULTIPOLYGON", 7: "GEOMETRYCOLLECTION"}


def geometry_summary(hex_ewkb):
    """Readable form of a geometry/geography value sent as hex EWKB."""
    try:
        data = bytes.fromhex(hex_ewkb)
        order = "<" if data[0] == 1 else ">"
        code = struct.unpack(order + "I", data[1:5])[0]
        name = GEOMETRY_TYPES.get((code & 0xFFFF) % 1000, "GEOMETRY")
        offset = 9 if code & 0x20000000 else 5  # skip the SRID if present
        if name == "POINT" and not code & 0xC0000000 and len(data) >= offset + 16:
            x, y = struct.unpack(order + "dd", data[offset:offset + 16])
            if x == x and y == y:  # not POINT EMPTY (NaN)
                return f"POINT({x:.6f} {y:.6f})"
        return f"[{name} – use ST_AsText(geom) to see coordinates]"
    except (ValueError, struct.error, IndexError):
        return "[geometry]"


def display(value, is_geometry=False):
    if value is None:
        return None
    if is_geometry:
        return geometry_summary(str(value))
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e15:
        return str(int(value))  # print 0 rather than 0.0, as psql does
    if isinstance(value, (decimal.Decimal, float, int)):
        return str(value)
    if isinstance(value, (datetime.date, datetime.datetime)):
        return value.isoformat()
    text = str(value)
    if len(text) > 120 and re.fullmatch(r"[0-9A-Fa-f]+", text):
        return "[geometry]"  # raw WKB is not useful in a table
    if len(text) > 400:
        return text[:400] + " …"  # e.g. a long hstore tag list
    return text


def table_rows(cursor, rows):
    geometry = [c.type_code in GEOMETRY_OIDS for c in cursor.description]
    return [[display(v, g) for v, g in zip(row, geometry)] for row in rows]


def load_schema_help():
    """Columns and row counts of the main relations, read from the database."""
    relations = ["places", "railway_stations", "roads", "major_roads", "areas",
                 "administrative_areas", "buildings", "metro_monorail_stations"]
    with connect() as conn:
        geometry_oids = {r[0] for r in conn.execute(
            "SELECT oid FROM pg_type WHERE typname IN ('geometry', 'geography')")}
        help_rows = []
        for rel in relations:
            columns = conn.execute(
                "SELECT column_name, udt_name FROM information_schema.columns "
                "WHERE table_schema = 'spatial_data' AND table_name = %s "
                "ORDER BY ordinal_position", [rel]).fetchall()
            count = conn.execute(f"SELECT count(*) FROM spatial_data.{rel}").fetchone()[0]
            help_rows.append({"name": f"spatial_data.{rel}", "rows": count,
                              "columns": [f"{c} ({t})" if c == "geom" else c for c, t in columns]})
        categories = [r[0] for r in conn.execute(
            "SELECT category FROM spatial_data.places GROUP BY category "
            "ORDER BY count(*) DESC LIMIT 15")]
    return geometry_oids, help_rows, categories


def load_location_choices():
    """Categories and railway stations (with coordinates) for the location search."""
    with connect() as conn:
        categories = [r[0] for r in conn.execute(
            "SELECT category FROM spatial_data.places GROUP BY category "
            "HAVING count(*) >= 20 ORDER BY count(*) DESC, category")]
        stations = [{"name": r[0], "lat": float(r[1]), "lon": float(r[2])} for r in conn.execute(
            "SELECT DISTINCT ON (name) name, round(ST_Y(geom)::numeric, 6), round(ST_X(geom)::numeric, 6) "
            "FROM spatial_data.railway_stations WHERE name IS NOT NULL ORDER BY name, id")]
    return categories, stations


# Extent of the Mumbai extract (config/project.env MUMBAI_BBOX), used for a warning only.
MUMBAI_BBOX = tuple(float(v) for v in os.environ.get("MUMBAI_BBOX", "72.75,18.85,73.05,19.30").split(","))


def location_sql(lat, lon, category, radius_m, mode, limit):
    """SQL for the location search. Every value is validated before it is
    written into the text, so the SQL shown on the page is exactly what runs."""
    point = f"ST_SetSRID(ST_Point({lon!r}, {lat!r}), 4326)"
    conditions = []
    if category != "any":
        conditions.append("category = '" + category.replace("'", "''") + "'")
    if mode == "radius":
        conditions.append(f"ST_DWithin(geom::geography, {point}::geography, {radius_m!r})")
        order = "distance_m, id"
    else:
        order = f"geom::geography <-> {point}::geography, id"  # KNN
    lines = [
        "SELECT name, category,",
        f"       round(ST_Distance(geom::geography, {point}::geography)::numeric, 1) AS distance_m,",
        "       round(ST_Y(geom)::numeric, 6) AS lat, round(ST_X(geom)::numeric, 6) AS lon",
        "FROM spatial_data.places",
    ]
    if conditions:
        lines.append("WHERE " + "\n  AND ".join(conditions))
    lines += [f"ORDER BY {order}", f"LIMIT {limit}"]
    if mode == "radius":
        return "\n".join(lines) + ";"
    # KNN finds the k nearest (sphere distance); re-sort them by the reported
    # spheroid distance so the distance column is always ascending.
    return ("SELECT * FROM (\n" + "\n".join("    " + line for line in lines)
            + "\n) nearest\nORDER BY distance_m;")


app = Flask(__name__)
CATALOG = load_catalog()
CHOICES = load_choices()
GEOMETRY_OIDS, SCHEMA_HELP, TOP_CATEGORIES = load_schema_help()
LOCATION_CATEGORIES, LOCATION_STATIONS = load_location_choices()


@app.get("/")
def index():
    groups = {}
    for block in CATALOG.values():
        groups.setdefault(block["file"], []).append(block)
    catalog = {
        qid: {"title": b["title"], "file": b["file"], "description": b["description"],
              "defaults": b["defaults"], "sql": ";\n\n".join(s["sql"] for s in b["statements"]) + ";"}
        for qid, b in CATALOG.items()
    }
    return render_template("index.html", groups=groups, catalog=catalog,
                           labels=PARAM_LABELS, choices=CHOICES, samples=SAMPLES,
                           schema=SCHEMA_HELP, categories=TOP_CATEGORIES,
                           location_categories=LOCATION_CATEGORIES, stations=LOCATION_STATIONS)


@app.post("/run")
def run():
    payload = request.get_json(silent=True) or {}
    block = CATALOG.get(payload.get("id"))
    if block is None:
        return jsonify(error="Unknown query."), 400
    try:
        params = validate(block, payload.get("params") or {})
    except ValueError as exc:
        return jsonify(error=str(exc)), 400

    results, notices = [], []
    started = time.perf_counter()
    try:
        with connect() as conn:
            conn.read_only = True
            conn.add_notice_handler(lambda diag: notices.append(diag.message_primary))
            try:
                with conn.cursor() as cur:
                    for statement in block["statements"]:
                        sql = statement["sql"].replace("%", "%%")
                        for literal, replacement in block["replacements"]:
                            sql = sql.replace(literal, replacement)
                        cur.execute(sql, params)
                        if cur.description is None:
                            continue  # e.g. SET LOCAL in the performance comparison
                        rows = cur.fetchmany(MAX_ROWS + 1)
                        results.append({
                            "caption": statement["caption"],
                            "columns": [c.name for c in cur.description],
                            "rows": table_rows(cur, rows[:MAX_ROWS]),
                            "truncated": len(rows) > MAX_ROWS,
                        })
            finally:
                conn.rollback()  # nothing is ever committed
    except psycopg.Error as exc:
        return jsonify(error=f"Database error: {exc}".strip()), 500

    return jsonify(id=block["id"], title=block["title"], params=params,
                   results=results, notices=notices,
                   elapsed_ms=round((time.perf_counter() - started) * 1000, 1))


@app.post("/nearby")
def nearby():
    """Search around a user-supplied latitude/longitude."""
    raw = request.get_json(silent=True) or {}

    def number(name, label, low, high):
        text = str(raw.get(name, "")).strip()
        if text == "":
            raise ValueError(f"{label} is required.")
        try:
            value = float(text)
        except ValueError:
            raise ValueError(f"{label} must be a number.") from None
        if not math.isfinite(value) or not low <= value <= high:
            raise ValueError(f"{label} must be between {low} and {high}.")
        return value

    try:
        lat = number("lat", "Latitude", -90, 90)
        lon = number("lon", "Longitude", -180, 180)
        mode = raw.get("mode", "nearest")
        if mode not in ("nearest", "radius"):
            raise ValueError("Unknown search type.")
        radius_m = number("radius_m", "Radius (metres)", 1, 50000) if mode == "radius" else None
        limit = int(number("limit", "Number of results", 1, 500))
        category = str(raw.get("category", "any"))
        if category != "any" and category not in LOCATION_CATEGORIES:
            raise ValueError(f"Unknown category: {category}")
    except ValueError as exc:
        return jsonify(ok=False, error=str(exc)), 400

    if radius_m is not None and radius_m.is_integer():
        radius_m = int(radius_m)
    sql = location_sql(lat, lon, category, radius_m, mode, limit)
    point = f"ST_SetSRID(ST_Point({lon!r}, {lat!r}), 4326)"
    started = time.perf_counter()
    try:
        with connect() as conn:
            conn.read_only = True
            try:
                cur = conn.execute(sql, prepare=True)
                columns = [c.name for c in cur.description]
                rows = table_rows(cur, cur.fetchall())
                ward = conn.execute(
                    "SELECT name FROM spatial_data.administrative_areas "
                    f"WHERE admin_level = '10' AND ST_Covers(geom, {point}) LIMIT 1").fetchone()
            finally:
                conn.rollback()
    except psycopg.Error as exc:
        return jsonify(ok=False, error=describe_db_error(exc, sql, 0)), 400

    west, south, east, north = MUMBAI_BBOX
    return jsonify(ok=True, sql=sql, columns=columns, rows=rows, row_count=len(rows),
                   elapsed_ms=round((time.perf_counter() - started) * 1000, 2),
                   ward=ward[0] if ward else None,
                   inside_extract=west <= lon <= east and south <= lat <= north)


CURSOR_PREFIX = 'DECLARE "live_console" CURSOR FOR '


def describe_db_error(exc, sql, offset):
    """PostgreSQL error text with the error position shown in the user's SQL."""
    diag = exc.diag
    lines = [diag.message_primary or str(exc).strip() or type(exc).__name__]
    if diag.statement_position:
        pos = int(diag.statement_position) - 1 - offset
        if 0 <= pos <= len(sql):
            line_no = sql.count("\n", 0, pos) + 1
            line_start = sql.rfind("\n", 0, pos) + 1
            line_end = sql.find("\n", pos)
            text = sql[line_start:line_end if line_end != -1 else len(sql)]
            lines += [f"LINE {line_no}: {text}", " " * (len(f"LINE {line_no}: ") + pos - line_start) + "^"]
    if diag.message_detail:
        lines.append("DETAIL: " + diag.message_detail)
    if diag.message_hint:
        lines.append("HINT: " + diag.message_hint)
    return "\n".join(lines)


@app.post("/sql")
def run_sql():
    """Live console: execute one validated read-only statement."""
    sql = str((request.get_json(silent=True) or {}).get("sql", ""))
    try:
        kind = live_sql.check(sql)
    except live_sql.RejectedSQL as exc:
        return jsonify(ok=False, stage="validation", error=str(exc)), 400

    notices = []
    query = sql.strip().rstrip("; \t\r\n")
    offset = 0 if kind == "explain" else len(CURSOR_PREFIX)
    started = time.perf_counter()
    try:
        with connect() as conn:
            conn.read_only = True
            conn.add_notice_handler(lambda diag: notices.append(diag.message_primary))
            try:
                if kind == "explain":
                    # prepare=True uses the extended protocol: one statement only.
                    cur = conn.execute(query, prepare=True)
                    plan = [str(row[0]) for row in cur.fetchall()]
                    result = {"plan": plan, "row_count": len(plan), "columns": [], "rows": []}
                else:
                    # A server-side cursor (DECLARE … CURSOR) accepts exactly one
                    # SELECT and refuses data-modifying WITH clauses.
                    with conn.cursor(name="live_console") as cur:
                        cur.execute(query)
                        rows = cur.fetchmany(LIVE_MAX_ROWS)
                        columns = [c.name for c in cur.description]
                        shown = table_rows(cur, rows)
                        remaining = 0
                        if len(rows) == LIVE_MAX_ROWS:
                            moved = conn.execute('MOVE FORWARD ALL IN "live_console"')
                            remaining = int(moved.statusmessage.split()[-1])
                    result = {"columns": columns, "rows": shown,
                              "row_count": len(rows) + remaining,
                              "truncated": remaining > 0}
                elapsed = round((time.perf_counter() - started) * 1000, 2)
            finally:
                conn.rollback()  # nothing is ever committed
    except psycopg.Error as exc:
        return jsonify(ok=False, stage="database", error=describe_db_error(exc, query, offset)), 400

    return jsonify(ok=True, kind=kind, elapsed_ms=elapsed, notices=notices,
                   max_rows=LIVE_MAX_ROWS, **result)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("WEB_PORT", "5050")))
