ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts search <term>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
if [ "$ALL" = 1 ]; then
  DESCFN="description"; LIMIT=""
else
  DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 50"
fi
query "SELECT attr AS package, version, $DESCFN
FROM packages
WHERE attr ILIKE '%' || '$ARG' || '%'
   OR description ILIKE '%' || '$ARG' || '%'
ORDER BY attr $LIMIT;"
