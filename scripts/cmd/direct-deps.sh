require_edges
ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts direct-deps <attr> [depth]" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
DEPTH="${ARGS[2]:-1}"
if ! echo "$DEPTH" | grep -qE '^[0-9]+$'; then
  echo "ERROR: depth must be a positive integer" >&2; exit 1
fi
if [ "$ALL" = 1 ]; then
  DESCFN="p.description"; LIMIT=""
else
  DESCFN="substr(p.description, 1, 80) AS description"; LIMIT="LIMIT 200"
fi
query "WITH RECURSIVE dep_tree AS (
  SELECT drv_path, 0 AS depth
  FROM packages WHERE attr ILIKE '$ARG'
  UNION
  SELECT e.input_drv, d.depth + 1
  FROM dep_tree d
  JOIN dependency_edges e ON d.drv_path = e.drv_path
  WHERE d.depth < $DEPTH
),
dep_summary AS (
  SELECT drv_path, min(depth) AS depth
  FROM dep_tree
  GROUP BY drv_path
  HAVING min(depth) > 0
)
SELECT ds.depth, p.attr AS package,
  (SELECT min(pp.attr) FROM dependency_edges e
   JOIN dep_summary pds ON e.drv_path = pds.drv_path
   JOIN packages pp ON e.drv_path = pp.drv_path
   WHERE e.input_drv = ds.drv_path
     AND pds.depth = ds.depth - 1
  ) AS required_by,
  p.version, $DESCFN
FROM dep_summary ds
JOIN packages p ON ds.drv_path = p.drv_path
ORDER BY ds.depth, p.attr $LIMIT;"
