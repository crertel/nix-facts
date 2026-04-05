if [ "$NDJSON" = 1 ]; then
  # File info as NDJSON
  BASE_SIZE="null"; BASE_EXISTS="false"
  if [ -f "@baseDb@" ]; then
    BASE_SIZE="\"$(du -h "@baseDb@" | cut -f1)\""
    BASE_EXISTS="true"
  fi
  ENRICHED_SIZE="null"; ENRICHED_EXISTS="false"; ENRICHED_STALE="false"
  if [ -f "@enrichedDb@" ]; then
    ENRICHED_SIZE="\"$(du -h "@enrichedDb@" | cut -f1)\""
    ENRICHED_EXISTS="true"
    if [ "@baseDb@" -nt "@enrichedDb@" ]; then
      ENRICHED_STALE="true"
    fi
  fi
  @jq@ -cn --arg bp "@baseDb@" --argjson bs "$BASE_SIZE" --argjson be "$BASE_EXISTS" \
          --arg ep "@enrichedDb@" --argjson es "$ENRICHED_SIZE" --argjson ee "$ENRICHED_EXISTS" --argjson est "$ENRICHED_STALE" \
    '{type:"database_file",path:$bp,size:$bs,exists:$be}'
  @jq@ -cn --arg bp "@baseDb@" --argjson bs "$BASE_SIZE" --argjson be "$BASE_EXISTS" \
          --arg ep "@enrichedDb@" --argjson es "$ENRICHED_SIZE" --argjson ee "$ENRICHED_EXISTS" --argjson est "$ENRICHED_STALE" \
    '{type:"database_file",path:$ep,size:$es,exists:$ee,stale:$est}'
  # Table counts as NDJSON
  printf '.mode json\n%s\n' \
    "SELECT 'packages' AS tbl, count(*) AS rows FROM packages
     UNION ALL SELECT 'package_maintainers', count(*) FROM package_maintainers
     UNION ALL SELECT 'package_platforms', count(*) FROM package_platforms;" \
    | @duckdb@ -readonly "$DB" | @jq@ -c '.[]'
  if @duckdb@ -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
    printf '.mode json\n%s\n' \
      "SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
       UNION ALL SELECT 'package_passthru', count(*) FROM package_passthru;" \
      | @duckdb@ -readonly "$DB" | @jq@ -c '.[]'
  fi
elif [ "$CSV" = 1 ]; then
  echo "base_db,@baseDb@"
  echo "enriched_db,@enrichedDb@"
  printf '.mode csv\n%s\n' \
    "SELECT 'packages' AS tbl, count(*) AS rows FROM packages
     UNION ALL SELECT 'package_maintainers', count(*) FROM package_maintainers
     UNION ALL SELECT 'package_platforms', count(*) FROM package_platforms;" \
    | @duckdb@ -readonly "$DB"
  if @duckdb@ -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
    printf '.mode csv\n%s\n' \
      "SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
       UNION ALL SELECT 'package_passthru', count(*) FROM package_passthru;" \
      | @duckdb@ -readonly "$DB"
  else
    echo "(enriched tables not available)"
  fi
else
  echo "=== Database files ==="
  printf "  Base DB:     %s\n" "@baseDb@"
  if [ -f "@baseDb@" ]; then
    SIZE=$(du -h "@baseDb@" | cut -f1)
    printf "               %s\n" "$SIZE"
  else
    printf "               (not found)\n"
  fi
  printf "  Enriched DB: %s\n" "@enrichedDb@"
  if [ -f "@enrichedDb@" ]; then
    SIZE=$(du -h "@enrichedDb@" | cut -f1)
    printf "               %s\n" "$SIZE"
    if [ "@baseDb@" -nt "@enrichedDb@" ]; then
      printf "               (stale — base DB is newer)\n"
    fi
  else
    printf "               (not found)\n"
  fi
  echo ""
  echo "=== Table row counts ==="
  @duckdb@ -readonly "$DB" <<'STATS_SQL'
.mode table
SELECT 'packages' AS tbl, count(*) AS rows FROM packages
UNION ALL
SELECT 'package_maintainers', count(*) FROM package_maintainers
UNION ALL
SELECT 'package_platforms', count(*) FROM package_platforms;
STATS_SQL
  if @duckdb@ -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
    @duckdb@ -readonly "$DB" <<'STATS_SQL'
.mode table
SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
UNION ALL
SELECT 'package_passthru', count(*) FROM package_passthru;
STATS_SQL
  else
    echo "(enriched tables not available)"
  fi
fi
