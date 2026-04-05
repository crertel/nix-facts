if [ "$ALL" = 1 ]; then
  DESCFN="description"; LIMIT=""
else
  DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 100"
fi
query "SELECT attr AS package, version, license, $DESCFN
FROM packages
WHERE unfree = true
ORDER BY attr $LIMIT;"
