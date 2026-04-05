require_passthru
if [ "$ALL" = 1 ]; then
  DESCFN="p.description"; LIMIT=""
else
  DESCFN="substr(p.description, 1, 80) AS description"; LIMIT="LIMIT 100"
fi
query "SELECT p.attr AS package, p.version, $DESCFN
FROM packages p
JOIN package_passthru pt ON p.attr = pt.attr
WHERE pt.has_update_script = false
  AND p.broken = false
ORDER BY p.attr $LIMIT;"
