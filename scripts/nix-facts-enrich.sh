set -euo pipefail

# Step 1: Extract attr paths from meta.ndjson and force-instantiate
# all derivations so their .drv files exist in the store.
echo ":: Extracting attr paths from meta.ndjson..."
@jq@ -r 'select(.error == null) | .attr' @metaJson@/meta.ndjson \
  | @jq@ -Rs 'split("\n") | map(select(. != ""))' > /tmp/nf_attrs.json
TOTAL=$(@jq@ 'length' /tmp/nf_attrs.json)
echo "  Found $TOTAL package attribute paths"

echo ":: Instantiating all derivations (evaluates nixpkgs, may take several minutes)..."
NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1 \
nix-instantiate --expr '
  let
    pkgs = import @nixpkgs@ { config = { allowUnfree = true; allowBroken = true; }; };
    lib = pkgs.lib;
    getByPath = path:
      lib.attrByPath (lib.splitString "." path) null pkgs;
    paths = builtins.fromJSON (builtins.readFile /tmp/nf_attrs.json);
    tryGet = p:
      let v = builtins.tryEval (
        let pkg = getByPath p;
        in if pkg != null && pkg ? drvPath
           then builtins.seq pkg.drvPath pkg
           else null
      );
      in if v.success && v.value != null then v.value else null;
  in builtins.filter (x: x != null) (map tryGet paths)
' > /tmp/nf_instantiated.txt 2>&1 || true
INSTANTIATED=$(grep -c '/nix/store/.*\.drv' /tmp/nf_instantiated.txt || echo 0)
echo "  Instantiated $INSTANTIATED derivations"

# Step 2: Extract drv paths and filter to those now in the store
echo ":: Extracting drv paths from meta.ndjson..."
@jq@ -r 'select(.error == null) | .drvPath // empty' @metaJson@/meta.ndjson \
  | sort -u > /tmp/nf_all_drvs.txt
DRVTOTAL=$(wc -l < /tmp/nf_all_drvs.txt)
echo "  Found $DRVTOTAL unique derivation paths"

: > /tmp/nf_valid_drvs.txt
while IFS= read -r drv; do
  [ -e "$drv" ] && echo "$drv" >> /tmp/nf_valid_drvs.txt
done < /tmp/nf_all_drvs.txt
VALID=$(wc -l < /tmp/nf_valid_drvs.txt)
echo "  $VALID / $DRVTOTAL derivations exist in store"

if [ "$VALID" -eq 0 ]; then
  echo "ERROR: No derivation files found in store." >&2
  rm -f /tmp/nf_attrs.json /tmp/nf_all_drvs.txt /tmp/nf_valid_drvs.txt
  exit 1
fi

# Step 3: Extract dependency edges
echo ":: Extracting dependency edges via nix derivation show..."
cat /tmp/nf_valid_drvs.txt \
  | xargs -n 2000 nix derivation show 2>/dev/null \
  | @jq@ -c 'to_entries[] | .key as $drv | (.value.inputDrvs // {}) | to_entries[] |
      {drv_path: $drv, input_drv: .key}' > /tmp/nf_edges.ndjson || true
EDGES=$(wc -l < /tmp/nf_edges.ndjson)
echo "  Generated $EDGES dependency edges"

if [ "$EDGES" -eq 0 ]; then
  echo "ERROR: Failed to extract any edges." >&2
  rm -f /tmp/nf_attrs.json /tmp/nf_instantiated.txt /tmp/nf_all_drvs.txt /tmp/nf_valid_drvs.txt /tmp/nf_edges.ndjson
  exit 1
fi

# Step 4: Extract passthru metadata (tests, updateScript)
echo ":: Extracting passthru metadata (has_tests, has_update_script)..."
NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1 \
nix-instantiate --eval --strict --json --expr '
  let
    pkgs = import @nixpkgs@ { config = { allowUnfree = true; allowBroken = true; }; };
    lib = pkgs.lib;
    getByPath = path:
      lib.attrByPath (lib.splitString "." path) null pkgs;
    paths = builtins.fromJSON (builtins.readFile /tmp/nf_attrs.json);
    check = p:
      let
        pkg = builtins.tryEval (getByPath p);
        hasTests = builtins.tryEval (
          pkg.value ? passthru &&
          pkg.value.passthru ? tests &&
          builtins.length (builtins.attrNames pkg.value.passthru.tests) > 0
        );
        hasUpdate = builtins.tryEval (
          pkg.value ? passthru &&
          pkg.value.passthru ? updateScript
        );
      in if pkg.success && pkg.value != null then {
        attr = p;
        has_tests = if hasTests.success then hasTests.value else false;
        has_update_script = if hasUpdate.success then hasUpdate.value else false;
      } else null;
  in builtins.filter (x: x != null) (map check paths)
' | @jq@ -c '.[]' > /tmp/nf_passthru.ndjson || true
PASSTHRU=$(wc -l < /tmp/nf_passthru.ndjson)
echo "  Extracted passthru info for $PASSTHRU packages"

# Step 5: Build enriched database
echo ":: Building enriched database..."
mkdir -p "$(dirname "@enrichedDb@")"
cp "@baseDb@" "@enrichedDb@"
chmod u+w "@enrichedDb@"

@duckdb@ "@enrichedDb@" <<ENRICH_SQL
  CREATE TABLE dependency_edges AS
  SELECT * FROM read_ndjson_auto('/tmp/nf_edges.ndjson');

  CREATE TABLE package_passthru AS
  SELECT * FROM read_ndjson_auto('/tmp/nf_passthru.ndjson');

  CREATE INDEX idx_dep_drv ON dependency_edges (drv_path);
  CREATE INDEX idx_dep_input ON dependency_edges (input_drv);
  CREATE INDEX idx_passthru_attr ON package_passthru (attr);
ENRICH_SQL

echo ":: Done. Enriched database at @enrichedDb@"
@duckdb@ -readonly "@enrichedDb@" <<'STATS_SQL'
  SELECT 'packages' AS tbl, count(*) AS rows FROM packages
  UNION ALL
  SELECT 'maintainers', count(*) FROM package_maintainers
  UNION ALL
  SELECT 'dep_edges', count(*) FROM dependency_edges
  UNION ALL
  SELECT 'passthru', count(*) FROM package_passthru;
STATS_SQL

rm -f /tmp/nf_attrs.json /tmp/nf_instantiated.txt /tmp/nf_all_drvs.txt /tmp/nf_valid_drvs.txt /tmp/nf_edges.ndjson /tmp/nf_passthru.ndjson
