require_edges
ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts dep-maintainers <attr>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
if [ "$ALL" = 1 ]; then LIMIT=""; else LIMIT="LIMIT 50"; fi
query "WITH RECURSIVE dep_tree AS (
  SELECT drv_path FROM packages WHERE attr ILIKE '$ARG'
  UNION
  SELECT e.input_drv FROM dep_tree d
  JOIN dependency_edges e ON d.drv_path = e.drv_path
)
SELECT pm.maintainer_github, pm.maintainer_name,
       count(DISTINCT p.attr) AS package_count
FROM dep_tree d
JOIN packages p ON d.drv_path = p.drv_path
JOIN package_maintainers pm ON p.attr = pm.attr
WHERE pm.maintainer_github IS NOT NULL
GROUP BY pm.maintainer_github, pm.maintainer_name
ORDER BY package_count DESC $LIMIT;"
