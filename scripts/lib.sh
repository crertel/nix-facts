# Common setup for nix-facts commands.
# Sourced by the main dispatcher — not executable on its own.

set -euo pipefail

# Use enriched DB if available, otherwise base DB
if [ -f "@enrichedDb@" ]; then
  DB="@enrichedDb@"
else
  DB="@baseDb@"
fi

ALL=0
CSV=0
NDJSON=0
QUIET=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --csv) CSV=1 ;;
    --ndjson) NDJSON=1 ;;
    --quiet|-q) QUIET=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

progress() {
  if [ "$QUIET" = 0 ]; then
    echo "$@" >&2
  fi
}

CMD="${ARGS[0]:-help}"

query() {
  if [ "$CSV" = 1 ]; then
    printf '.mode csv\n%s\n' "$1" | @duckdb@ -readonly "$DB"
  elif [ "$NDJSON" = 1 ]; then
    printf '.mode json\n%s\n' "$1" | @duckdb@ -readonly "$DB" | @jq@ -c '.[]'
  else
    printf '.mode table\n.maxrows 100000\n%s\n' "$1" | @duckdb@ -readonly "$DB"
  fi
}

require_edges() {
  if ! @duckdb@ -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
    echo "ERROR: Dependency edges not available. Run 'nix-facts-enrich' first." >&2
    exit 1
  fi
}

require_passthru() {
  if ! @duckdb@ -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
    echo "ERROR: Passthru metadata not available. Run 'nix-facts-enrich' first." >&2
    exit 1
  fi
}

usage() {
  echo "Usage: nix-facts <command> [options] [args...]"
  echo ""
  echo "Commands:"
  echo "  search <term>         Search packages by name/description"
  echo "  info <attr>           Show all metadata for a package"
  echo "  maintainers <attr>    Maintainers of a package"
  echo "  maintainer <github>   Packages by maintainer GitHub handle"
  echo "  top-maintainers       Top maintainers by package count"
  echo "  orphans               Packages with no maintainers"
  echo "  broken                Packages marked as broken"
  echo "  unfree                Packages marked as unfree"
  echo "  platforms <attr>      Supported platforms for a package"
  echo "  no-tests              Packages without tests (needs enrich)"
  echo "  no-update-script      Packages without update scripts (needs enrich)"
  echo "  deps <attr>           Transitive dependencies (needs enrich)"
  echo "  direct-deps <attr> [depth]  Dependencies to given depth (needs enrich)"
  echo "  dep-maintainers <attr> Maintainers of transitive deps (needs enrich)"
  echo "  audit-system          Health audit of the running NixOS system"
  echo "  audit-devshell <ref>  Health audit of a flake's dev shell closure"
  echo "  stats                 Database sizes and row counts"
  echo "  db [args...]          Raw DuckDB session"
  echo ""
  echo "Options:"
  echo "  --all      Show full results (no row limits or truncation)"
  echo "  --csv      Output as CSV"
  echo "  --ndjson   Output as NDJSON (one JSON object per line)"
  echo "  --quiet/-q Suppress progress messages on stderr"
  echo ""
  echo "Run 'nix-facts-enrich' to enable deps/dep-maintainers commands."
}
