#!/usr/bin/env bash
# check-zone-serial-bumped.sh — a staged DNS zone whose content changed must
# also raise its SOA serial.
#
# WHY THIS EXISTS (2026-09-12)
#
# `ssh.forgejo IN A 10.10.30.51` was added to the zone in
# infrastructure/cluster-dns/configmap.yaml. Argo CD reported Synced + Healthy
# at that revision, the live ConfigMap carried the record, the file reached the
# CoreDNS pod, and CoreDNS logged nothing. `dig` returned the OLD address,
# 10/10, with the authoritative-answer bit set.
#
# CoreDNS's `file` plugin re-reads a zone ONLY when the SOA serial INCREASES
# (it polls, once a minute by default); the serial was still 1, so the process
# kept answering from the copy it parsed at start-up. The block-level `reload`
# directive is not a safety net — it watches the COREFILE, not zone files;
# upstream sends zone-file watching to the `auto` plugin. The change was
# therefore applied at every layer that reports and served by none. Bumping the
# serial to 2 fixed it in ~80 s.
#
# That is the highest-value class of bug to automate away: every reporting
# layer says success. Hence a commit-time guard.
#
# WHAT IT CHECKS
#
# For every file STAGED for commit that carries an SOA record, the staged zone
# is compared against the HEAD zone:
#   * zone content changed and the serial did NOT strictly increase  -> FAIL
#   * zone content changed and the serial DID increase               -> OK
#   * zone content unchanged (only comments / a sibling YAML key)    -> OK
#   * the file (or the zone) is new, with no HEAD counterpart        -> OK
# A file with no staged change is not in scope at all. Scope comes from the
# data — any staged file containing an SOA record — not from a path list or a
# `--only-X` flag (CLAUDE.md, "let data declare scope").
#
# PARSING NOTES — read these before editing the parser
#
#  * The serial is NOT a fixed field number. In
#      `@   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )`
#    awk's $6 is the literal `(` and $7 is the serial; an owner-less
#    continuation form shifts both. A check that reads a guessed column can
#    never match the serial, so its failure branch becomes unreachable and it
#    reports green while checking nothing. This parser therefore anchors on the
#    SOA token itself, takes MNAME and RNAME positionally FROM IT, and then
#    takes the first integer after them, skipping parens.
#  * Both RFC 1035 SOA layouts are supported: single-line `( ... )` and the
#    multi-line form where the parenthesis continues across lines.
#  * `;` comments are stripped quote-aware before comparison, so a comment-only
#    edit to a zone does not demand a serial bump (CoreDNS does not read them).
#
# WHAT COUNTS AS A ZONE (and what merely mentions one)
#
# A candidate region is the body of a YAML block scalar (`db.zone: |`) holding
# an SOA, or a whole file whose SOA sits at column 0. A candidate is treated as
# a zone only if EVERY content line of it reads as a zone-file line — a
# `$DIRECTIVE` or `<owner> [ttl] [class] TYPE <rdata>`. That last rule is
# load-bearing: this script's own header, the hook registration in
# .pre-commit-config.yaml and the control suite all quote a literal SOA record,
# and without it the guard failed every commit that touched itself (caught
# 2026-09-12 on its first repo-wide run, before it was committed).
#
# SHAPES REFUSED LOUDLY (exit 1 — never silently mis-parsed). The region is a
# zone, but this script will not guess:
#   * two SOA records inside one zone region (which zone changed is unknowable);
#   * `$INCLUDE`, where content can change in a file this check never sees;
#   * an SOA whose serial does not parse as an integer.
# Each says what to do instead. "I cannot read this, bump it manually" is better
# than mis-parsing a shape the parser did not expect.
#
# SHAPES NOT RECOGNISED AS ZONES AT ALL (skipped silently, by design):
#   * a zone stored as an indented YAML *quoted* scalar or as JSON, rather than
#     a block scalar — the only sane container for a multi-line zone is `|`, and
#     treating every other indented SOA as a zone means treating every comment
#     that documents one as a zone too;
#   * a zone written with lowercase types or classes (`ns in a 10.0.0.1`). Legal
#     per RFC 1035, absent from BIND canonical output and from this repo; the
#     alternative — matching types case-insensitively — makes ordinary English
#     prose parse as resource records.
# Both are false negatives, so they are stated here rather than discovered: if a
# zone ever lands in one of these shapes, this guard is silent about it.
#
# Usage: check-zone-serial-bumped.sh [--repo <dir>]   (default: this repo)
# Exit 0 = clean. Exit 1 = a zone changed without a bump, or an unreadable zone.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) awk '/^set -euo/{exit} {print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "FAIL: unknown argument: $1 (usage: $(basename "$0") [--repo <dir>])" >&2; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required by $(basename "$0")" >&2; exit 1; }
[ -d "$REPO" ] || { echo "FAIL: --repo is not a directory: $REPO" >&2; exit 1; }

python3 - "$REPO" <<'PY'
import re
import subprocess
import sys

repo = sys.argv[1]
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

INCIDENT = (
    "2026-09-12: ssh.forgejo was added with the serial left at 1. Argo reported\n"
    "  Synced+Healthy, the ConfigMap carried the record, the pod had the file,\n"
    "  nothing was logged -- and dig returned the OLD address, authoritative, 10/10."
)


def git(*args):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    return p.returncode, p.stdout, p.stderr


def git_text(*args):
    rc, out, err = git(*args)
    if rc != 0:
        return None
    try:
        return out.decode("utf-8")
    except UnicodeDecodeError:
        return None


# --- zone parsing -----------------------------------------------------------

CLASSES = {"IN", "CS", "CH", "HS"}        # case-sensitive on purpose: see NOT RECOGNISED
TTL = re.compile(r"^\d+[smhdwSMHDW]?$")
INT = re.compile(r"^\d+$")
TYPE = re.compile(r"^[A-Z][A-Z0-9-]*$")   # A, AAAA, NS, SOA, CAA, SVCB, TLSA, ...
# `key: |`, `key: |-`, `key: >2` ... a YAML block scalar header.
BLOCK_KEY = re.compile(r"^(\s*)([^\s#][^:]*):[ \t]*[|>][-+0-9]*[ \t]*$")


def strip_comment(line):
    """Drop a `;` comment, honouring double-quoted strings (TXT rdata)."""
    out = []
    quoted = False
    escaped = False
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\":
            out.append(ch)
            escaped = True
            continue
        if ch == '"':
            quoted = not quoted
        elif ch == ";" and not quoted:
            break
        out.append(ch)
    return "".join(out)


def tokens(line):
    """Whitespace fields, with `(` and `)` peeled into tokens of their own."""
    out = []
    for raw in strip_comment(line).split():
        t = raw
        while t.startswith("(") and len(t) > 1:
            out.append("(")
            t = t[1:]
        tail = []
        while t.endswith(")") and len(t) > 1:
            tail.append(")")
            t = t[:-1]
        if t:
            out.append(t)
        out.extend(tail)
    return out


def soa_index(tk):
    """Index of the SOA type token, or None.

    Accepts `<owner> [ttl] [class] SOA` and the owner-less continuation form
    `[ttl] [class] SOA`. Everything between the owner slot and SOA must be a
    TTL or a class, which is what keeps the word SOA inside a TXT string or a
    hostname from being read as a record type.
    """
    for i, t in enumerate(tk):
        if t.upper() != "SOA":
            continue
        if i < 1:
            return None
        if all(p in CLASSES or TTL.match(p) for p in tk[1:i]):
            return i
        return None
    return None


def soa_serial(lines, i, idx):
    """Serial of the SOA starting on lines[i] at token idx, or None.

    Anchored, never positional-by-column: skip MNAME and RNAME, then take the
    first integer, stepping over `(`. Continues onto following lines while the
    parenthesis is open, which is the multi-line RFC 1035 layout.
    """
    tk = tokens(lines[i])[idx:]
    depth = tk.count("(") - tk.count(")")
    j = i
    while depth > 0 and j + 1 < len(lines) and len(tk) < 64:
        j += 1
        nxt = tokens(lines[j])
        tk += nxt
        depth += nxt.count("(") - nxt.count(")")
    for t in tk[3:]:  # tk[0]=SOA, tk[1]=MNAME, tk[2]=RNAME
        if t == "(":
            continue
        return int(t) if INT.match(t) else None
    return None


def is_zone_line(tk):
    """True if these tokens are a zone-file line: a `$DIRECTIVE`, or a resource
    record `<owner> [ttl] [class] TYPE <rdata...>`. Blank and comment-only lines
    arrive here as an empty token list and are accepted."""
    if not tk:
        return True
    if tk[0].startswith("$"):
        return True
    for i in range(1, min(4, len(tk))):
        if TYPE.match(tk[i]) and all(p in CLASSES or TTL.match(p) for p in tk[1:i]):
            return True
    return False


def is_zone_body(lines):
    """True only if EVERY content line of the candidate region is a zone-file
    line. This is what separates a zone from prose that merely quotes an SOA --
    this script's own header, the hook registration, a runbook. One line of
    English or shell is enough to disqualify the block."""
    depth = 0
    seen = False
    for ln in lines:
        tk = tokens(ln)
        if depth > 0:              # inside an open `( ... )`: a continuation line
            depth += tk.count("(") - tk.count(")")
            continue
        if not tk:
            continue
        if not is_zone_line(tk):
            return False
        seen = True
        depth += tk.count("(") - tk.count(")")
    return seen


def dedent(lines):
    strip = [ln for ln in lines if ln.strip()]
    if not strip:
        return lines
    pad = min(len(ln) - len(ln.lstrip(" ")) for ln in strip)
    return [ln[pad:] if ln.strip() else "" for ln in lines]


def normalize(lines):
    """Zone content as CoreDNS sees it: no comments, no blank lines, no
    trailing whitespace, and insensitive to the YAML indent of the block."""
    out = []
    for ln in dedent(lines):
        s = strip_comment(ln).rstrip()
        if s.strip():
            out.append(s)
    return "\n".join(out)


class Unreadable(Exception):
    pass


def zone_regions(text):
    """{region name: (normalized content, serial)} for every zone in a file.

    A zone at column 0 is the whole file (a standalone zone file). An indented
    zone is the body of its enclosing YAML block scalar, named by that key --
    so a sibling key in the same ConfigMap (the Corefile, which `reload` does
    watch) is correctly NOT part of the zone.
    """
    lines = text.split("\n")

    # 1. Candidate regions: the container around each SOA-looking line.
    spans = []
    for i, ln in enumerate(lines):
        if soa_index(tokens(ln)) is None:
            continue
        indent = len(ln) - len(ln.lstrip(" \t"))
        if indent == 0:
            span = ("<whole file>", 0, len(lines))
        else:
            key = None
            for j in range(i - 1, -1, -1):
                m = BLOCK_KEY.match(lines[j])
                if m and len(m.group(1)) < indent:
                    key = (j, len(m.group(1)), m.group(2).strip())
                    break
            if key is None:
                # Indented, with no block-scalar header above it: a comment, a
                # docstring, a heredoc in a test -- prose ABOUT a zone, not a
                # zone. Not a candidate. See NOT RECOGNISED in the header.
                continue
            j, key_indent, name = key
            start = j + 1
            end = start
            while end < len(lines):
                cur = lines[end]
                if cur.strip() and (len(cur) - len(cur.lstrip(" \t"))) <= key_indent:
                    break
                end += 1
            span = (name, start, end)
        if span not in spans:
            spans.append(span)

    # 2. Keep only candidates whose every content line reads as a zone file.
    regions = {}
    for name, start, end in spans:
        body = lines[start:end]
        if not is_zone_body(body):
            continue
        if name in regions:
            raise Unreadable("two zone regions are both named %r; cannot tell them apart" % name)
        if any(ln.lstrip().startswith("$INCLUDE") for ln in body):
            raise Unreadable(
                "zone %r uses $INCLUDE; its content can change in a file this check "
                "never sees, so a serial bump cannot be verified here" % name
            )
        found = [(k, soa_index(tokens(body[k]))) for k in range(len(body))]
        found = [(k, x) for k, x in found if x is not None]
        if len(found) != 1:
            raise Unreadable(
                "zone %r holds %d SOA records (lines %s); which zone changed is "
                "unknowable. Give each zone its own key or file."
                % (name, len(found), ", ".join(str(start + k + 1) for k, _ in found))
            )
        k, x = found[0]
        serial = soa_serial(body, k, x)
        if serial is None:
            raise Unreadable(
                "the SOA serial in zone %r does not parse as an integer: %r"
                % (name, body[k].strip())
            )
        regions[name] = (normalize(body), serial)
    return regions


# --- scope: staged files, old path resolved through renames -----------------

rc, _, _ = git("rev-parse", "--verify", "-q", "HEAD")
base = "HEAD" if rc == 0 else EMPTY_TREE

rc, out, err = git("diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=ACMR", base)
if rc != 0:
    print("FAIL: cannot read the staged changes: %s" % err.decode("utf-8", "replace").strip(), file=sys.stderr)
    raise SystemExit(1)

fields = out.decode("utf-8", "surrogateescape").split("\0")
staged = []  # (path in index, path in base or None)
n = 0
while n < len(fields):
    status = fields[n]
    if not status:
        break
    if status.startswith("R") or status.startswith("C"):
        staged.append((fields[n + 2], fields[n + 1]))
        n += 3
    else:
        staged.append((fields[n + 1], None if status.startswith("A") else fields[n + 1]))
        n += 2

problems = []
notes = []
checked = 0

for path, old_path in staged:
    new_text = git_text("show", ":%s" % path)
    if new_text is None:
        continue  # binary, or unreadable from the index
    old_text = git_text("show", "%s:%s" % (base, old_path)) if old_path else None

    try:
        new_zones = zone_regions(new_text)
    except Unreadable as e:
        problems.append("%s: %s" % (path, e))
        continue
    if not new_zones and old_text is None:
        continue
    try:
        old_zones = zone_regions(old_text) if old_text is not None else {}
    except Unreadable as e:
        if new_zones:
            problems.append("%s (HEAD version): %s" % (path, e))
        continue
    if not new_zones and not old_zones:
        continue

    for name, (new_body, new_serial) in sorted(new_zones.items()):
        where = "%s [%s]" % (path, name)
        if name not in old_zones:
            notes.append("%s: new zone (serial %d), nothing to compare" % (where, new_serial))
            continue
        old_body, old_serial = old_zones[name]
        checked += 1
        if new_body == old_body:
            notes.append("%s: zone content unchanged (serial %d)" % (where, old_serial))
        elif new_serial > old_serial:
            notes.append("%s: zone changed, serial %d -> %d" % (where, old_serial, new_serial))
        else:
            problems.append(
                "%s: the zone content changed but the SOA serial did not increase "
                "(HEAD %d, staged %d)" % (where, old_serial, new_serial)
            )
    for name in sorted(set(old_zones) - set(new_zones)):
        notes.append("%s [%s]: zone removed" % (path, name))

if problems:
    for p in problems:
        print("FAIL: %s" % p, file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "  precondition: CoreDNS's `file` plugin re-reads a zone ONLY when the SOA\n"
        "  serial INCREASES (it polls, 1 min by default). The `reload` directive\n"
        "  watches the Corefile, not zone files -- upstream sends zone-file watching\n"
        "  to the `auto` plugin -- so nothing else catches this.\n"
        "  now: the staged zone differs from %s while the serial does not advance;\n"
        "  committing it would apply the change at every layer that reports and\n"
        "  serve it at none.\n"
        "  converge: raise the serial on the SOA line (the first number in the\n"
        "  parentheses -- NOT a fixed column), re-stage the file, commit again.\n"
        "  %s" % (base if base == "HEAD" else "the base tree", INCIDENT),
        file=sys.stderr,
    )
    raise SystemExit(1)

if checked == 0 and not notes:
    print("OK: no staged file carries a DNS zone (SOA record) -- nothing to check.")
else:
    print("OK: %d staged zone(s) compared against %s." % (checked, base))
for note in notes:
    print("  %s" % note)
PY
