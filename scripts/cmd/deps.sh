require_edges
ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts deps <attr>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
if [ "$ALL" = 1 ]; then
  DESCFN="description"; LIMIT=""
else
  DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 50"
fi
query "WITH RECURSIVE dep_tree AS (
  SELECT drv_path FROM packages WHERE attr ILIKE '$ARG'
  UNION
  SELECT e.input_drv FROM dep_tree d
  JOIN dependency_edges e ON d.drv_path = e.drv_path
)
SELECT DISTINCT p.attr AS package, p.version, $DESCFN
FROM dep_tree d JOIN packages p ON d.drv_path = p.drv_path
WHERE p.attr NOT ILIKE '$ARG'
ORDER BY p.attr $LIMIT;"
