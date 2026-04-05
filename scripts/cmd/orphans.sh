if [ "$ALL" = 1 ]; then
  DESCFN="p.description"; LIMIT=""
else
  DESCFN="substr(p.description, 1, 60) AS description"; LIMIT="LIMIT 100"
fi
query "SELECT p.attr AS package, p.version, $DESCFN
FROM packages p
LEFT JOIN package_maintainers pm ON p.attr = pm.attr
WHERE pm.attr IS NULL
ORDER BY p.attr $LIMIT;"
