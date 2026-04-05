ARG="${ARGS[1]:-}"
if [ -z "$ARG" ]; then echo "Usage: nix-facts maintainers <attr>" >&2; exit 1; fi
ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
query "SELECT pm.maintainer_github, pm.maintainer_name
FROM package_maintainers pm
WHERE pm.attr ILIKE '$ARG'
ORDER BY pm.maintainer_github;"
