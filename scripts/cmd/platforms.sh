ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts platforms <attr>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
query "SELECT pp.platform
FROM package_platforms pp
WHERE pp.attr ILIKE '$ARG'
ORDER BY pp.platform;"
