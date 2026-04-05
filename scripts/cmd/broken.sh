if [ "$ALL" = 1 ]; then
  DESCFN="description"; LIMIT=""
else
  DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 100"
fi
query "SELECT attr AS package, version, $DESCFN
FROM packages
WHERE broken = true
ORDER BY attr $LIMIT;"
