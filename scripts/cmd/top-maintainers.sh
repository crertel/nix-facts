if [ "$ALL" = 1 ]; then LIMIT=""; else LIMIT="LIMIT 50"; fi
query "SELECT maintainer_github, maintainer_name, count(*) AS package_count
FROM package_maintainers
WHERE maintainer_github IS NOT NULL
GROUP BY maintainer_github, maintainer_name
ORDER BY package_count DESC $LIMIT;"
