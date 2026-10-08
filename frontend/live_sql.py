"""Validation for the live SQL console: one read-only query per request.

This is the application-level check. The database enforces read-only access
independently (role mumbai_web: SELECT-only privileges, read-only
transactions, statement timeout), so a query that slipped past this check
still could not change anything.
"""
import re

MAX_SQL_LENGTH = 20000

# Statement keywords that write data, change schema, change settings, control
# transactions or run administrative commands. Matched as whole words outside
# string literals, quoted identifiers and comments.
FORBIDDEN_WORDS = {
    "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "TRUNCATE", "COPY", "INTO",
    "CREATE", "ALTER", "DROP", "RENAME", "COMMENT", "SECURITY",
    "GRANT", "REVOKE", "OWNER",
    "BEGIN", "START", "COMMIT", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE",
    "SET", "RESET", "DISCARD", "LOCK",
    "CALL", "DO", "EXECUTE", "PREPARE", "DEALLOCATE",
    "VACUUM", "ANALYZE", "ANALYSE", "CLUSTER", "REINDEX", "REFRESH", "CHECKPOINT",
    "LISTEN", "UNLISTEN", "NOTIFY", "LOAD", "IMPORT",
}

# Functions with side effects (settings, sleeping, server/file access, sequences, locks).
FORBIDDEN_FUNCTIONS = re.compile(
    r"^(SET_CONFIG|PG_SLEEP\w*|PG_TERMINATE_BACKEND|PG_CANCEL_BACKEND|PG_RELOAD_CONF|"
    r"PG_ROTATE_LOGFILE|PG_READ_\w+|PG_LS_\w+|PG_STAT_FILE|PG_FILE_\w+|LO_\w+|DBLINK\w*|"
    r"NEXTVAL|SETVAL|PG_ADVISORY\w*|PG_TRY_ADVISORY\w*|PG_NOTIFY|QUERY_TO_XML\w*|"
    r"TABLE_TO_XML\w*|CURSOR_TO_XML\w*|DATABASE_TO_XML\w*|SCHEMA_TO_XML\w*)$"
)

EXPLAIN_PREFIX = re.compile(
    r"^EXPLAIN\s*(\([^()]*\))?\s*((ANALYZE|ANALYSE|VERBOSE)\s+)*", re.IGNORECASE
)


class RejectedSQL(ValueError):
    pass


def strip_literals(sql):
    """Return the SQL with comments removed and literal contents blanked.

    String literals become '' and quoted identifiers become "", so keywords
    inside them are not mistaken for commands. E'...' strings honour
    backslash escapes; dollar-quoted strings are refused.
    """
    out, i, n = [], 0, len(sql)
    while i < n:
        ch = sql[i]
        if sql.startswith("--", i):
            while i < n and sql[i] != "\n":
                i += 1
        elif sql.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            if depth:
                raise RejectedSQL("Unterminated /* comment.")
            out.append(" ")
        elif ch == "'":
            escapes = i > 0 and sql[i - 1] in "eE" and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            i += 1
            while True:
                if i >= n:
                    raise RejectedSQL("Unterminated string literal.")
                if escapes and sql[i] == "\\":
                    i += 2
                    continue
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            out.append("''")
        elif ch == '"':
            i += 1
            while True:
                if i >= n:
                    raise RejectedSQL("Unterminated quoted identifier.")
                if sql[i] == '"':
                    if i + 1 < n and sql[i + 1] == '"':
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            out.append('"x"')
        elif ch == "$":
            raise RejectedSQL("Dollar-quoted strings and $n parameters are not supported in the console.")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def check(sql):
    """Validate console SQL. Returns 'select' or 'explain'; raises RejectedSQL."""
    if len(sql) > MAX_SQL_LENGTH:
        raise RejectedSQL(f"Query is longer than {MAX_SQL_LENGTH} characters.")
    code = strip_literals(sql).strip()
    code = re.sub(r"[;\s]+$", "", code)
    if not code:
        raise RejectedSQL("Enter a SQL query.")
    if ";" in code:
        raise RejectedSQL("Only one statement can be run at a time (remove the extra ';').")

    kind = "select"
    body = code
    if re.match(r"EXPLAIN\b", code, re.IGNORECASE):
        kind = "explain"
        body = code[EXPLAIN_PREFIX.match(code).end():]

    first = re.match(r"\(*\s*([A-Za-z_]+)", body)
    first_word = first.group(1).upper() if first else ""
    if first_word not in ("SELECT", "WITH", "VALUES", "TABLE"):
        if kind == "explain":
            raise RejectedSQL("EXPLAIN is only allowed for SELECT / WITH … SELECT queries.")
        raise RejectedSQL(
            f"Only read-only queries are allowed: SELECT, WITH … SELECT, EXPLAIN [ANALYZE] "
            f"(this statement starts with {first_word or 'something else'}).")

    words = {w.upper() for w in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", body)}
    blocked = sorted(words & FORBIDDEN_WORDS)
    if blocked:
        raise RejectedSQL("Not allowed in the read-only console: " + ", ".join(blocked) + ".")
    blocked = sorted(w for w in words if FORBIDDEN_FUNCTIONS.match(w))
    if blocked:
        raise RejectedSQL("Function not allowed in the read-only console: " + ", ".join(blocked).lower() + ".")
    return kind
