#!/usr/bin/env bash
# Verify every relative link in markdown files resolves —
# both the file path AND the optional `#anchor` fragment.
#
# Why: docs cross-link heavily (ADRs ↔ runbooks ↔ journal
# entries) and across repos (homelab-k8s and homelab-infra
# READMEs link into homelab-docs). A renamed runbook leaves
# dangling refs scattered around; a renamed section leaves
# anchors pointing at nothing. The 2026-05-03 broken-link
# sweep agent flagged the gap (path-only check missed anchor
# drift + cross-repo links from siblings); this script closes
# both.
#
# Per the operator's "script everything scriptable now" policy
# (memory feedback_script-don-t-defer.md).
#
# Scope:
# - Relative links only. `[text](path)` and `[text](path#anchor)`.
#   Absolute http(s) / mailto / ftp links are skipped.
# - Image links `![alt](path)` checked the same way.
# - Anchors validated against the target file's headings using
#   GitHub-flavored kebab-case slug rules (lowercase; drop
#   non-alphanumeric except hyphen + underscore; spaces →
#   hyphens; duplicates get `-1`, `-2`, … in document order).
# - `#L<n>` and `#L<n>-L<m>` anchors skipped — those are
#   GitHub source-line refs, not heading anchors.
# - Code fences (```…```) skipped — links inside fenced code
#   blocks are illustrative, not real refs.
# - The script's OWN file (this one) is excluded — sample
#   patterns inside this script's comments would otherwise be
#   parsed as live links.
#
# Cross-repo: when a link resolves out of this repo (e.g.,
# `../../homelab-k8s/...`), the script follows it. Sibling
# repos must be checked out at the same parent for cross-repo
# links to resolve — that's the canonical layout per ADR 0001.
# When a single repo is checked out alone, sibling-targeted
# links will fail; that's expected and useful (catches the
# missing-sibling case).
#
# Exit 0 = clean. Exit 1 = at least one broken link / anchor.
#
# Skip the anchor-validation pass entirely:
#   SKIP_ANCHOR_CHECK=1 scripts/check-broken-links.sh
# (escape hatch if a slug edge-case surfaces; please file an
# issue rather than leaving SKIP_ANCHOR_CHECK on permanently.)

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$REPO_ROOT"

# Find every markdown file. Excludes: .git/, the scripts/
# directory itself (this script + its siblings shouldn't be
# treated as docs).
md_files=$(find . -type f -name '*.md' \
    -not -path './.git/*' \
    -not -path './scripts/*')

# Slug cache: avoid re-extracting headings from the same target
# file when many links point to it. Implemented as a Bash 4
# associative array; keyed by absolute path.
declare -A SLUG_CACHE

# Extract GitHub-flavored kebab-case heading slugs from a file.
# Output: one slug per line, in document order, with dedup
# suffixes applied. Skips fenced code blocks.
extract_slugs() {
    local file="$1"
    awk '
        /^```/ { in_fence = !in_fence; next }
        !in_fence && /^#+[[:space:]]+/ {
            heading = $0
            # Strip leading hashes + whitespace.
            sub(/^#+[[:space:]]+/, "", heading)
            # Strip trailing whitespace + optional anchor
            # `{#explicit-id}` (some markdown processors).
            sub(/[[:space:]]+$/, "", heading)
            sub(/[[:space:]]*\{#[^}]+\}[[:space:]]*$/, "", heading)
            # Strip inline backticks (heading text inside `...`
            # contributes its content, not the ticks).
            gsub(/`/, "", heading)
            # Lowercase.
            heading = tolower(heading)
            # Drop non-ASCII non-(alnum|space|hyphen|underscore).
            gsub(/[^a-z0-9 _-]/, "", heading)
            # Spaces → hyphens (no consecutive-hyphen collapse).
            gsub(/ /, "-", heading)
            # Dedup with GitHub-style numeric suffix.
            if (heading in seen) {
                seen[heading]++
                print heading "-" seen[heading]
            } else {
                seen[heading] = 0
                print heading
            }
        }
    ' "$file"
}

# Cached wrapper.
slugs_for() {
    local key="$1"
    if [ -z "${SLUG_CACHE[$key]+isset}" ]; then
        SLUG_CACHE[$key]="$(extract_slugs "$key")"
    fi
    printf '%s\n' "${SLUG_CACHE[$key]}"
}

skip_anchor_check="${SKIP_ANCHOR_CHECK:-}"

out=$(
    for md in $md_files; do
        # Skip this script's own source if accidentally renamed
        # to .md (defensive).
        [ "$(realpath "$md")" = "$SCRIPT_PATH" ] && continue

        md_dir=$(dirname "$md")

        # Strip code fences, then extract every `[text](link)`.
        awk '
            /^```/ { in_fence = !in_fence; next }
            !in_fence { print }
        ' "$md" \
        | grep -oE '\]\([^)]+\)' \
        | sed -E 's/^\]\(//; s/\)$//' \
        | while IFS= read -r link; do
            # Skip absolute URLs.
            case "$link" in
                http://*|https://*|mailto:*|ftp://*) continue ;;
            esac

            target="${link%%#*}"
            anchor=""
            case "$link" in
                *'#'*) anchor="${link#*#}" ;;
            esac

            # Pure in-page anchor (no path) — link is `#foo`;
            # the target IS the source file. Skip path
            # resolution; the file obviously exists.
            if [ -z "$target" ]; then
                full_path="$md"
                check_path="$md"
            else
                full_path="$md_dir/$target"
                check_path="${full_path%/}"
            fi

            # Path resolution.
            if [ ! -e "$check_path" ] && [ ! -e "$check_path/" ]; then
                echo "FAIL: $md → $link (path not found at $full_path)"
                continue
            fi

            # Anchor validation (skip if disabled, no anchor, or
            # target is a directory).
            [ -n "$skip_anchor_check" ] && continue
            [ -z "$anchor" ] && continue
            [ -d "$check_path" ] && continue

            # Skip GitHub source-line anchors.
            case "$anchor" in
                L[0-9]*) continue ;;
            esac

            # Resolve to absolute path so the slug cache
            # collapses cross-repo target paths spelled
            # differently from different source files.
            target_abs=$(realpath "$check_path" 2>/dev/null || echo "")
            [ -z "$target_abs" ] && continue
            [ ! -f "$target_abs" ] && continue

            # Only validate anchors for markdown targets;
            # other file types (yaml, sh, …) don't have
            # heading slugs.
            case "$target_abs" in
                *.md) ;;
                *) continue ;;
            esac

            slugs=$(slugs_for "$target_abs")
            if ! printf '%s\n' "$slugs" | grep -Fxq "$anchor"; then
                echo "FAIL: $md → $link (anchor '#$anchor' not in target's headings)"
            fi
        done
    done
)

if [ -z "$out" ]; then
    count=$(echo "$md_files" | wc -l | tr -d ' ')
    if [ -n "$skip_anchor_check" ]; then
        echo "OK: all relative paths resolve across $count markdown files (anchor check skipped)."
    else
        echo "OK: all relative links + anchors resolve across $count markdown files."
    fi
    exit 0
fi

echo "$out" >&2
broken_count=$(echo "$out" | grep -c '^FAIL:' || true)
echo >&2
echo "FAIL: $broken_count broken link(s) / anchor(s)." >&2
echo "Most likely causes: a runbook / ADR was renamed or moved;" >&2
echo "or a heading was renamed without updating its anchor refs." >&2
echo "Find the new location with \`ls\` / \`find\` / \`grep -nE '^#+'\`," >&2
echo "then update the linker. Set SKIP_ANCHOR_CHECK=1 to bypass" >&2
echo "the anchor pass if a slug edge-case surfaces." >&2
exit 1
