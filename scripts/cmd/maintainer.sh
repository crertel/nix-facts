ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts maintainer <github-handle>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
if [ "$ALL" = 1 ]; then
  DESCFN="p.description"; LIMIT=""
else
  DESCFN="substr(p.description, 1, 60) AS description"; LIMIT="LIMIT 200"
fi
query "SELECT pm.attr AS package, p.version, $DESCFN
FROM package_maintainers pm
JOIN packages p ON pm.attr = p.attr
WHERE pm.maintainer_github ILIKE '$ARG'
ORDER BY pm.attr $LIMIT;"
