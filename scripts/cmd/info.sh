ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts info <attr>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
if @duckdb@ -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
  PASSTHRU_COLS=", pt.has_tests, pt.has_update_script"
  PASSTHRU_JOIN="LEFT JOIN package_passthru pt ON p.attr = pt.attr"
else
  PASSTHRU_COLS=""
  PASSTHRU_JOIN=""
fi
query "SELECT p.attr AS package, p.name, p.version, p.description, p.homepage,
   p.license, p.main_program, p.broken, p.unfree,
   CASE WHEN p.position IS NOT NULL THEN
     regexp_extract(p.position, '/nix/store/[^/]+/(.*)', 1)
   ELSE NULL END AS source,
   p.drv_path, to_json(p.maintainers) AS maintainers
   $PASSTHRU_COLS
FROM packages p $PASSTHRU_JOIN
WHERE p.attr ILIKE '$ARG';"
