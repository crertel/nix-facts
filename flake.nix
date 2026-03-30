{
  description = "Queryable DuckDB database of nixpkgs package metadata";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      packages = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Stage 1: Evaluate all of nixpkgs and dump package metadata to JSON.
          # Requires `sandbox = relaxed` in nix.conf because nix-env needs
          # store access to evaluate nixpkgs expressions.
          meta-json =
            pkgs.runCommand "nixpkgs-meta-json"
              {
                __noChroot = true;
                nativeBuildInputs = [ pkgs.nix ];
              }
              ''
                # Preload nixpkgs source into tmpfs so the evaluator reads
                # ~100K small .nix files from RAM instead of random disk I/O.
                WORK=$(mktemp -d --tmpdir nixpkgs-eval.XXXXXXXXXX)
                cp -a ${nixpkgs} "$WORK/nixpkgs"

                mkdir -p $out
                NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1 \
                  nix-env -f "$WORK/nixpkgs" -qaP --meta --drv-path --json > $out/meta.json
              '';

          # Stage 2: Convert the JSON dump into a DuckDB database with three tables:
          #   packages            — one row per attribute path
          #   package_maintainers — unnested (attr, maintainer) junction table
          #   package_platforms   — unnested (attr, platform) junction table
          meta-db =
            pkgs.runCommand "nixpkgs-meta-db"
              {
                nativeBuildInputs = [
                  pkgs.duckdb
                  pkgs.jq
                ];
              }
              ''
                            mkdir -p $out

                            echo ":: Converting to NDJSON (packages)..."
                            jq -c 'to_entries[] | {
                              attr: .key,
                              name: .value.name,
                              pname: (.value.pname // null),
                              version: (.value.version // null),
                              drv_path: (.value.drvPath // null),
                              description: (.value.meta.description // null),
                              homepage: (
                                (.value.meta.homepage // null) |
                                if type == "array" then .[0] // null else . end
                              ),
                              position: (.value.meta.position // null),
                              main_program: (.value.meta.mainProgram // null),
                              broken: (.value.meta.broken // false),
                              unfree: (.value.meta.unfree // false),
                              license: (
                                (.value.meta.license // null) |
                                if type == "array" then
                                  [.[] | .spdxId // .shortName // .fullName // "unknown"] | join(", ")
                                elif type == "object" then
                                  .spdxId // .shortName // .fullName // "unknown"
                                elif type == "string" then .
                                else null end
                              ),
                              maintainers: [(.value.meta.maintainers // [])[] | .github // empty]
                            }' ${meta-json}/meta.json > /tmp/packages.ndjson

                            echo ":: Converting to NDJSON (maintainers)..."
                            jq -c 'to_entries[] |
                              .key as $attr | .value.name as $name |
                              (.value.meta.maintainers // [])[] |
                              {
                                attr: $attr,
                                name: $name,
                                maintainer_name:   (.name // null),
                                maintainer_github: (.github // null),
                                maintainer_email:  (.email // null)
                              }' ${meta-json}/meta.json > /tmp/maintainers.ndjson

                            echo ":: Converting to NDJSON (platforms)..."
                            jq -c 'to_entries[] |
                              .key as $attr |
                              (.value.meta.platforms // [])[] |
                              if type == "string" then
                                {attr: $attr, platform: .}
                              else empty end' ${meta-json}/meta.json > /tmp/platforms.ndjson

                            echo ":: Loading into DuckDB..."
                            duckdb $out/meta.db <<'SQL'
                              CREATE TABLE packages AS
                              SELECT * FROM read_ndjson_auto('/tmp/packages.ndjson');

                              CREATE TABLE package_maintainers AS
                              SELECT * FROM read_ndjson_auto('/tmp/maintainers.ndjson');

                              CREATE TABLE package_platforms AS
                              SELECT * FROM read_ndjson_auto('/tmp/platforms.ndjson');

                              CREATE INDEX idx_maintainer_github
                              ON package_maintainers (maintainer_github);

                              CREATE INDEX idx_platform
                              ON package_platforms (platform);

                              CREATE INDEX idx_pkg_drv ON packages (drv_path);
                SQL

                            echo ":: Done."
                            duckdb -readonly $out/meta.db <<'SQL'
                              SELECT 'packages' AS tbl, count(*) AS rows FROM packages
                              UNION ALL
                              SELECT 'maintainers', count(*) FROM package_maintainers
                              UNION ALL
                              SELECT 'platforms', count(*) FROM package_platforms;
                SQL
              '';
        in
        {
          inherit meta-json meta-db;
          default = meta-db;
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          meta-db = self.packages.${system}.meta-db;
          meta-json = self.packages.${system}.meta-json;
          base-db = "${meta-db}/meta.db";
          enriched-db = "$HOME/.cache/nix-facts/meta.db";
          duckdb = "${pkgs.duckdb}/bin/duckdb";
          jq = "${pkgs.jq}/bin/jq";
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.duckdb
              pkgs.jq

              # Enrich the base DB with dependency edges (runs outside Nix build
              # so it has full daemon access for nix derivation show)
              (pkgs.writeShellScriptBin "nix-facts-enrich" ''
                                set -euo pipefail

                                # Step 1: Extract attr paths from meta.json and force-instantiate
                                # all derivations so their .drv files exist in the store.
                                echo ":: Extracting attr paths from meta.json..."
                                ${jq} 'keys' ${meta-json}/meta.json > /tmp/nf_attrs.json
                                TOTAL=$(${jq} 'length' /tmp/nf_attrs.json)
                                echo "  Found $TOTAL package attribute paths"

                                echo ":: Instantiating all derivations (evaluates nixpkgs, may take several minutes)..."
                                NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1 \
                                nix-instantiate --expr '
                                  let
                                    pkgs = import ${nixpkgs} { config = { allowUnfree = true; allowBroken = true; }; };
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
                                echo ":: Extracting drv paths from meta.json..."
                                ${jq} -r 'to_entries[].value.drvPath // empty' ${meta-json}/meta.json \
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
                                  | ${jq} -c 'to_entries[] | .key as $drv | (.value.inputDrvs // {}) | to_entries[] |
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
                                    pkgs = import ${nixpkgs} { config = { allowUnfree = true; allowBroken = true; }; };
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
                                ' | ${jq} -c '.[]' > /tmp/nf_passthru.ndjson || true
                                PASSTHRU=$(wc -l < /tmp/nf_passthru.ndjson)
                                echo "  Extracted passthru info for $PASSTHRU packages"

                                # Step 5: Build enriched database
                                echo ":: Building enriched database..."
                                mkdir -p "$(dirname "${enriched-db}")"
                                cp "${base-db}" "${enriched-db}"
                                chmod u+w "${enriched-db}"

                                ${duckdb} "${enriched-db}" <<ENRICH_SQL
                                  CREATE TABLE dependency_edges AS
                                  SELECT * FROM read_ndjson_auto('/tmp/nf_edges.ndjson');

                                  CREATE TABLE package_passthru AS
                                  SELECT * FROM read_ndjson_auto('/tmp/nf_passthru.ndjson');

                                  CREATE INDEX idx_dep_drv ON dependency_edges (drv_path);
                                  CREATE INDEX idx_dep_input ON dependency_edges (input_drv);
                                  CREATE INDEX idx_passthru_attr ON package_passthru (attr);
                ENRICH_SQL

                                echo ":: Done. Enriched database at ${enriched-db}"
                                ${duckdb} -readonly "${enriched-db}" <<'STATS_SQL'
                                  SELECT 'packages' AS tbl, count(*) AS rows FROM packages
                                  UNION ALL
                                  SELECT 'maintainers', count(*) FROM package_maintainers
                                  UNION ALL
                                  SELECT 'dep_edges', count(*) FROM dependency_edges
                                  UNION ALL
                                  SELECT 'passthru', count(*) FROM package_passthru;
                STATS_SQL

                                rm -f /tmp/nf_attrs.json /tmp/nf_instantiated.txt /tmp/nf_all_drvs.txt /tmp/nf_valid_drvs.txt /tmp/nf_edges.ndjson /tmp/nf_passthru.ndjson
              '')

              (pkgs.writeShellScriptBin "nix-facts" ''
                                set -euo pipefail

                                # Use enriched DB if available, otherwise base DB
                                if [ -f "${enriched-db}" ]; then
                                  DB="${enriched-db}"
                                else
                                  DB="${base-db}"
                                fi

                                ALL=0
                                CSV=0
                                NDJSON=0
                                QUIET=0
                                ARGS=()
                                for arg in "$@"; do
                                  case "$arg" in
                                    --all) ALL=1 ;;
                                    --csv) CSV=1 ;;
                                    --ndjson) NDJSON=1 ;;
                                    --quiet|-q) QUIET=1 ;;
                                    *) ARGS+=("$arg") ;;
                                  esac
                                done

                                progress() {
                                  if [ "$QUIET" = 0 ]; then
                                    echo "$@" >&2
                                  fi
                                }

                                CMD="''${ARGS[0]:-help}"

                                query() {
                                  if [ "$CSV" = 1 ]; then
                                    printf '.mode csv\n%s\n' "$1" | ${duckdb} -readonly "$DB"
                                  elif [ "$NDJSON" = 1 ]; then
                                    printf '.mode json\n%s\n' "$1" | ${duckdb} -readonly "$DB" | ${jq} -c '.[]'
                                  else
                                    printf '.mode table\n.maxrows 100000\n%s\n' "$1" | ${duckdb} -readonly "$DB"
                                  fi
                                }

                                require_edges() {
                                  if ! ${duckdb} -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
                                    echo "ERROR: Dependency edges not available. Run 'nix-facts-enrich' first." >&2
                                    exit 1
                                  fi
                                }

                                require_passthru() {
                                  if ! ${duckdb} -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
                                    echo "ERROR: Passthru metadata not available. Run 'nix-facts-enrich' first." >&2
                                    exit 1
                                  fi
                                }

                                usage() {
                                  echo "Usage: nix-facts <command> [options] [args...]"
                                  echo ""
                                  echo "Commands:"
                                  echo "  search <term>         Search packages by name/description"
                                  echo "  info <attr>           Show all metadata for a package"
                                  echo "  maintainers <attr>    Maintainers of a package"
                                  echo "  maintainer <github>   Packages by maintainer GitHub handle"
                                  echo "  top-maintainers       Top maintainers by package count"
                                  echo "  orphans               Packages with no maintainers"
                                  echo "  broken                Packages marked as broken"
                                  echo "  unfree                Packages marked as unfree"
                                  echo "  platforms <attr>      Supported platforms for a package"
                                  echo "  no-tests              Packages without tests (needs enrich)"
                                  echo "  no-update-script      Packages without update scripts (needs enrich)"
                                  echo "  deps <attr>           Transitive dependencies (needs enrich)"
                                  echo "  direct-deps <attr> [depth]  Dependencies to given depth (needs enrich)"
                                  echo "  dep-maintainers <attr> Maintainers of transitive deps (needs enrich)"
                                  echo "  audit [target]        Health audit of a runtime closure"
                                  echo "  stats                 Database sizes and row counts"
                                  echo "  db [args...]          Raw DuckDB session"
                                  echo ""
                                  echo "Options:"
                                  echo "  --all      Show full results (no row limits or truncation)"
                                  echo "  --csv      Output as CSV"
                                  echo "  --ndjson   Output as NDJSON (one JSON object per line)"
                                  echo "  --quiet/-q Suppress progress messages on stderr"
                                  echo ""
                                  echo "Run 'nix-facts-enrich' to enable deps/dep-maintainers commands."
                                }

                                case "$CMD" in
                                  search)
                                    ARG="''${ARGS[1]:-}"
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
                                    ;;

                                  info)
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts info <attr>" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    if ${duckdb} -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
                                      PASSTHRU_COLS=", pt.has_tests, pt.has_update_script"
                                      PASSTHRU_JOIN="LEFT JOIN package_passthru pt ON p.attr = pt.attr"
                                    else
                                      PASSTHRU_COLS=""
                                      PASSTHRU_JOIN=""
                                    fi
                                    query "SELECT p.attr AS package, p.name, p.version, p.description, p.homepage,
                                       p.license, p.main_program, p.broken, p.unfree,
                                       CASE WHEN p.position IS NOT NULL THEN
                                         regexp_extract(p.position, '.*/nixpkgs/(.*)$', 1)
                                       ELSE NULL END AS source,
                                       p.drv_path, to_json(p.maintainers) AS maintainers
                                       $PASSTHRU_COLS
                                FROM packages p $PASSTHRU_JOIN
                                WHERE p.attr ILIKE '$ARG';"
                                    ;;

                                  maintainers)
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts maintainers <attr>" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    query "SELECT pm.maintainer_github, pm.maintainer_name
                                FROM package_maintainers pm
                                WHERE pm.attr ILIKE '$ARG'
                                ORDER BY pm.maintainer_github;"
                                    ;;

                                  maintainer)
                                    ARG="''${ARGS[1]:-}"
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
                                    ;;

                                  top-maintainers)
                                    if [ "$ALL" = 1 ]; then LIMIT=""; else LIMIT="LIMIT 50"; fi
                                    query "SELECT maintainer_github, maintainer_name, count(*) AS package_count
                                FROM package_maintainers
                                WHERE maintainer_github IS NOT NULL
                                GROUP BY maintainer_github, maintainer_name
                                ORDER BY package_count DESC $LIMIT;"
                                    ;;

                                  orphans)
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
                                    ;;

                                  broken)
                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="description"; LIMIT=""
                                    else
                                      DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 100"
                                    fi
                                    query "SELECT attr AS package, version, $DESCFN
                                FROM packages
                                WHERE broken = true
                                ORDER BY attr $LIMIT;"
                                    ;;

                                  unfree)
                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="description"; LIMIT=""
                                    else
                                      DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 100"
                                    fi
                                    query "SELECT attr AS package, version, license, $DESCFN
                                FROM packages
                                WHERE unfree = true
                                ORDER BY attr $LIMIT;"
                                    ;;

                                  platforms)
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts platforms <attr>" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    query "SELECT pp.platform
                                FROM package_platforms pp
                                WHERE pp.attr ILIKE '$ARG'
                                ORDER BY pp.platform;"
                                    ;;

                                  no-tests)
                                    require_passthru
                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="p.description"; LIMIT=""
                                    else
                                      DESCFN="substr(p.description, 1, 80) AS description"; LIMIT="LIMIT 100"
                                    fi
                                    query "SELECT p.attr AS package, p.version, $DESCFN
                                FROM packages p
                                JOIN package_passthru pt ON p.attr = pt.attr
                                WHERE pt.has_tests = false
                                  AND p.broken = false
                                ORDER BY p.attr $LIMIT;"
                                    ;;

                                  no-update-script)
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
                                    ;;

                                  deps)
                                    require_edges
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts deps <attr>" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="description"; LIMIT=""
                                    else
                                      DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 50"
                                    fi
                                    query "WITH RECURSIVE dep_tree AS (
                                  SELECT drv_path FROM packages WHERE attr ILIKE '$ARG'
                                  UNION
                                  SELECT e.input_drv FROM dep_tree d
                                  JOIN dependency_edges e ON d.drv_path = e.drv_path
                                )
                                SELECT DISTINCT p.attr AS package, p.version, $DESCFN
                                FROM dep_tree d JOIN packages p ON d.drv_path = p.drv_path
                                WHERE p.attr NOT ILIKE '$ARG'
                                ORDER BY p.attr $LIMIT;"
                                    ;;

                                  direct-deps)
                                    require_edges
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts direct-deps <attr> [depth]" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    DEPTH="''${ARGS[2]:-1}"
                                    if ! echo "$DEPTH" | grep -qE '^[0-9]+$'; then
                                      echo "ERROR: depth must be a positive integer" >&2; exit 1
                                    fi
                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="p.description"; LIMIT=""
                                    else
                                      DESCFN="substr(p.description, 1, 80) AS description"; LIMIT="LIMIT 200"
                                    fi
                                    query "WITH RECURSIVE dep_tree AS (
                                  SELECT drv_path, 0 AS depth
                                  FROM packages WHERE attr ILIKE '$ARG'
                                  UNION
                                  SELECT e.input_drv, d.depth + 1
                                  FROM dep_tree d
                                  JOIN dependency_edges e ON d.drv_path = e.drv_path
                                  WHERE d.depth < $DEPTH
                                ),
                                dep_summary AS (
                                  SELECT drv_path, min(depth) AS depth
                                  FROM dep_tree
                                  GROUP BY drv_path
                                  HAVING min(depth) > 0
                                )
                                SELECT ds.depth, p.attr AS package,
                                  (SELECT min(pp.attr) FROM dependency_edges e
                                   JOIN dep_summary pds ON e.drv_path = pds.drv_path
                                   JOIN packages pp ON e.drv_path = pp.drv_path
                                   WHERE e.input_drv = ds.drv_path
                                     AND pds.depth = ds.depth - 1
                                  ) AS required_by,
                                  p.version, $DESCFN
                                FROM dep_summary ds
                                JOIN packages p ON ds.drv_path = p.drv_path
                                ORDER BY ds.depth, p.attr $LIMIT;"
                                    ;;

                                  dep-maintainers)
                                    require_edges
                                    ARG="''${ARGS[1]:-}"
                                    if [ -z "$ARG" ]; then echo "Usage: nix-facts dep-maintainers <attr>" >&2; exit 1; fi
                                    ARG=$(printf '%s' "$ARG" | sed "s/'/'''/g")
                                    if [ "$ALL" = 1 ]; then LIMIT=""; else LIMIT="LIMIT 50"; fi
                                    query "WITH RECURSIVE dep_tree AS (
                                  SELECT drv_path FROM packages WHERE attr ILIKE '$ARG'
                                  UNION
                                  SELECT e.input_drv FROM dep_tree d
                                  JOIN dependency_edges e ON d.drv_path = e.drv_path
                                )
                                SELECT pm.maintainer_github, pm.maintainer_name,
                                       count(DISTINCT p.attr) AS package_count
                                FROM dep_tree d
                                JOIN packages p ON d.drv_path = p.drv_path
                                JOIN package_maintainers pm ON p.attr = pm.attr
                                WHERE pm.maintainer_github IS NOT NULL
                                GROUP BY pm.maintainer_github, pm.maintainer_name
                                ORDER BY package_count DESC $LIMIT;"
                                    ;;

                                  audit)
                                    # Phase A: Resolve input to a store path
                                    AUDIT_TARGET="''${ARGS[1]:-}"
                                    if [ -z "$AUDIT_TARGET" ]; then
                                      if [ -e /run/current-system ]; then
                                        STORE_PATH="/run/current-system"
                                        progress "Auditing current running system..."
                                      else
                                        echo "ERROR: /run/current-system not found (not NixOS?)." >&2
                                        echo "Please provide a target: nix-facts audit <flake-ref|.nix file|store path>" >&2
                                        exit 1
                                      fi
                                    elif [[ "$AUDIT_TARGET" == /nix/store/* ]]; then
                                      if [ ! -e "$AUDIT_TARGET" ]; then
                                        echo "ERROR: Store path does not exist: $AUDIT_TARGET" >&2
                                        exit 1
                                      fi
                                      STORE_PATH="$AUDIT_TARGET"
                                      progress "Auditing store path: $STORE_PATH"
                                    elif [[ "$AUDIT_TARGET" == *.nix ]] && [ -f "$AUDIT_TARGET" ]; then
                                      progress "Building $AUDIT_TARGET..."
                                      if ! STORE_PATH=$(nix-build --no-out-link "$AUDIT_TARGET"); then
                                        echo "ERROR: nix-build failed." >&2
                                        exit 1
                                      fi
                                      STORE_PATH=$(echo "$STORE_PATH" | grep '^/nix/store/' | head -n1)
                                      progress "Auditing: $STORE_PATH"
                                    elif [[ "$AUDIT_TARGET" == *#* ]]; then
                                      progress "Building $AUDIT_TARGET..."
                                      if ! STORE_PATH=$(nix build --no-link --print-out-paths "$AUDIT_TARGET"); then
                                        echo "ERROR: nix build failed." >&2
                                        exit 1
                                      fi
                                      STORE_PATH=$(echo "$STORE_PATH" | grep '^/nix/store/' | head -n1)
                                      progress "Auditing: $STORE_PATH"
                                    else
                                      progress "Building $AUDIT_TARGET..."
                                      if ! STORE_PATH=$(nix build --no-link --print-out-paths "$AUDIT_TARGET"); then
                                        echo "ERROR: nix build failed." >&2
                                        exit 1
                                      fi
                                      STORE_PATH=$(echo "$STORE_PATH" | grep '^/nix/store/' | head -n1)
                                      progress "Auditing: $STORE_PATH"
                                    fi

                                    # Phase B: Get closure and extract package names
                                    AUDIT_TMP=$(mktemp -d)
                                    trap 'rm -rf "$AUDIT_TMP"' EXIT

                                    progress "Querying closure..."
                                    nix-store -qR "$STORE_PATH" > "$AUDIT_TMP/out_paths.txt"
                                    CLOSURE_SIZE=$(wc -l < "$AUDIT_TMP/out_paths.txt")
                                    progress "Closure contains $CLOSURE_SIZE store paths"

                                    # Extract package names from store paths (/nix/store/<32-char-hash>-<name>)
                                    progress "Extracting package names..."
                                    while IFS= read -r path; do
                                      basename "$path" | cut -c34-
                                    done < "$AUDIT_TMP/out_paths.txt" \
                                      | sort -u | ${jq} -Rc '{name: .}' > "$AUDIT_TMP/closure_names.ndjson"
                                    NAME_COUNT=$(wc -l < "$AUDIT_TMP/closure_names.ndjson")
                                    progress "Found $NAME_COUNT unique package names"

                                    if [ "$NAME_COUNT" -eq 0 ]; then
                                      echo "WARNING: No package names found in closure." >&2
                                      exit 0
                                    fi

                                    # Phase C: Query database and output results
                                    CLOSURE_NDJSON="$AUDIT_TMP/closure_names.ndjson"

                                    # Check for enriched DB
                                    HAS_PASSTHRU=0
                                    if ${duckdb} -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
                                      HAS_PASSTHRU=1
                                    fi

                                    if [ "$ALL" = 1 ]; then
                                      DESCFN="description"; LIMIT=""
                                    else
                                      DESCFN="substr(description, 1, 80) AS description"; LIMIT="LIMIT 25"
                                    fi

                                    if [ "$NDJSON" = 1 ]; then
                                      # Summary object
                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        SUMMARY_SQL="WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) AS matched_packages,
                                          count(CASE WHEN len(maintainers) > 0 THEN 1 END) AS with_maintainers,
                                          printf('%.1f%%', 100.0 * count(CASE WHEN len(maintainers) > 0 THEN 1 END) / NULLIF(count(*), 0)) AS maintainer_pct,
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_tests = true) AS with_tests,
                                          printf('%.1f%%', 100.0 * (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_tests = true) / NULLIF(count(*), 0)) AS test_pct,
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true) AS with_update_script,
                                          printf('%.1f%%', 100.0 * (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true) / NULLIF(count(*), 0)) AS update_script_pct
                                        FROM closure_pkgs;"
                                      else
                                        SUMMARY_SQL="WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) AS matched_packages,
                                          count(CASE WHEN len(maintainers) > 0 THEN 1 END) AS with_maintainers,
                                          printf('%.1f%%', 100.0 * count(CASE WHEN len(maintainers) > 0 THEN 1 END) / NULLIF(count(*), 0)) AS maintainer_pct
                                        FROM closure_pkgs;"
                                      fi
                                      printf '.mode json\n%s\n' "$SUMMARY_SQL" \
                                        | ${duckdb} -readonly "$DB" \
                                        | ${jq} -c '.[] + {type: "summary", store_path: "'"$STORE_PATH"'", closure_size: '"$CLOSURE_SIZE"'}'

                                      # Top maintainers
                                      printf '.mode json\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT pm.maintainer_github, pm.maintainer_name,
                                             count(DISTINCT cp.attr) AS package_count
                                      FROM closure_pkgs cp
                                      JOIN package_maintainers pm ON cp.attr = pm.attr
                                      WHERE pm.maintainer_github IS NOT NULL
                                      GROUP BY pm.maintainer_github, pm.maintainer_name
                                      ORDER BY package_count DESC;" \
                                        | ${duckdb} -readonly "$DB" \
                                        | ${jq} -c '.[] + {type: "maintainer"}'

                                      # Unmaintained packages
                                      printf '.mode json\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT attr AS package, version FROM closure_pkgs
                                      WHERE len(maintainers) = 0
                                      ORDER BY attr;" \
                                        | ${duckdb} -readonly "$DB" \
                                        | ${jq} -c '.[] + {type: "unmaintained"}'

                                      # Gaps for enriched-only metrics
                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        printf '.mode json\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT cp.attr AS package, cp.version FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_tests IS NULL OR pt.has_tests = false
                                        ORDER BY cp.attr;" \
                                          | ${duckdb} -readonly "$DB" \
                                          | ${jq} -c '.[] + {type: "no_tests"}'

                                        printf '.mode json\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT cp.attr AS package, cp.version FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_update_script IS NULL OR pt.has_update_script = false
                                        ORDER BY cp.attr;" \
                                          | ${duckdb} -readonly "$DB" \
                                          | ${jq} -c '.[] + {type: "no_update_script"}'
                                      fi

                                    elif [ "$CSV" = 1 ]; then
                                      # Summary as metric/value CSV
                                      echo "metric,value"
                                      echo "store_path,$STORE_PATH"
                                      echo "closure_size,$CLOSURE_SIZE"
                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        SUMMARY_SQL="WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) AS matched,
                                          count(CASE WHEN len(maintainers) > 0 THEN 1 END) AS with_maintainers,
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_tests = true) AS with_tests,
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true) AS with_update_script
                                        FROM closure_pkgs;"
                                      else
                                        SUMMARY_SQL="WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) AS matched,
                                          count(CASE WHEN len(maintainers) > 0 THEN 1 END) AS with_maintainers
                                        FROM closure_pkgs;"
                                      fi
                                      printf '.mode csv\n.headers off\n%s\n' "$SUMMARY_SQL" \
                                        | ${duckdb} -readonly "$DB" \
                                        | while IFS=, read -r matched maintainers tests update_script rest; do
                                            echo "matched_packages,$matched"
                                            echo "with_maintainers,$maintainers"
                                            if [ -n "$tests" ]; then
                                              echo "with_tests,$tests"
                                              echo "with_update_script,$update_script"
                                            fi
                                          done
                                      echo ""

                                      # Top maintainers
                                      echo "maintainer_github,maintainer_name,package_count"
                                      printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT pm.maintainer_github, pm.maintainer_name,
                                             count(DISTINCT cp.attr) AS package_count
                                      FROM closure_pkgs cp
                                      JOIN package_maintainers pm ON cp.attr = pm.attr
                                      WHERE pm.maintainer_github IS NOT NULL
                                      GROUP BY pm.maintainer_github, pm.maintainer_name
                                      ORDER BY package_count DESC;" \
                                        | ${duckdb} -readonly "$DB"
                                      echo ""

                                      # Unmaintained gap list
                                      echo "gap_type,package,version"
                                      printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT 'unmaintained', attr, version FROM closure_pkgs
                                      WHERE len(maintainers) = 0
                                      ORDER BY attr;" \
                                        | ${duckdb} -readonly "$DB"

                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT 'no_tests', cp.attr, cp.version FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_tests IS NULL OR pt.has_tests = false
                                        ORDER BY cp.attr;" \
                                          | ${duckdb} -readonly "$DB"

                                        printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT 'no_update_script', cp.attr, cp.version FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_update_script IS NULL OR pt.has_update_script = false
                                        ORDER BY cp.attr;" \
                                          | ${duckdb} -readonly "$DB"
                                      fi

                                    else
                                      # Table output (default)
                                      echo "=== Closure Audit ==="
                                      echo "  Store path:    $STORE_PATH"
                                      echo "  Closure size:  $CLOSURE_SIZE store paths"

                                      # Get match count
                                      MATCHED=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT count(*) FROM closure_pkgs;" \
                                        | ${duckdb} -readonly "$DB" | tr -d '[:space:]')
                                      echo "  Matched pkgs:  $MATCHED of $NAME_COUNT package names"

                                      if [ "$MATCHED" = "0" ]; then
                                        echo ""
                                        echo "WARNING: No packages matched. The nix-facts database may be from a"
                                        echo "different nixpkgs revision than the audited closure."
                                        exit 0
                                      fi

                                      echo ""

                                      # Coverage stats — percentages computed in DuckDB to avoid bc dependency
                                      echo "=== Coverage ==="
                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT
                                          count(CASE WHEN len(maintainers) > 0 THEN 1 END),
                                          count(*),
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_tests = true),
                                          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true)
                                        FROM closure_pkgs;" \
                                          | ${duckdb} -readonly "$DB" \
                                          | while IFS=, read -r maint total tests upd; do
                                              printf "  Maintainers:     %s / %s (%s%%)\n" "$maint" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $maint / $total}")"
                                              printf "  Tests:           %s / %s (%s%%)\n" "$tests" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $tests / $total}")"
                                              printf "  Update scripts:  %s / %s (%s%%)\n" "$upd" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $upd / $total}")"
                                            done
                                      else
                                        printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(CASE WHEN len(maintainers) > 0 THEN 1 END), count(*)
                                        FROM closure_pkgs;" \
                                          | ${duckdb} -readonly "$DB" \
                                          | while IFS=, read -r maint total; do
                                              printf "  Maintainers:     %s / %s (%s%%)\n" "$maint" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $maint / $total}")"
                                            done
                                        echo ""
                                        echo "  (Run 'nix-facts-enrich' for test and update script coverage)"
                                      fi

                                      echo ""

                                      # Top maintainers in closure
                                      MAINT_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT count(DISTINCT pm.maintainer_github)
                                      FROM closure_pkgs cp
                                      JOIN package_maintainers pm ON cp.attr = pm.attr
                                      WHERE pm.maintainer_github IS NOT NULL;" \
                                        | ${duckdb} -readonly "$DB" | tr -d '[:space:]')

                                      if [ "$MAINT_TOTAL" != "0" ]; then
                                        echo "=== Top maintainers in closure ($MAINT_TOTAL total) ==="
                                        query "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT pm.maintainer_github, pm.maintainer_name,
                                               count(DISTINCT cp.attr) AS package_count
                                        FROM closure_pkgs cp
                                        JOIN package_maintainers pm ON cp.attr = pm.attr
                                        WHERE pm.maintainer_github IS NOT NULL
                                        GROUP BY pm.maintainer_github, pm.maintainer_name
                                        ORDER BY package_count DESC $LIMIT;"
                                        if [ "$ALL" != 1 ] && [ "$MAINT_TOTAL" -gt 25 ]; then
                                          echo "(showing 25 of $MAINT_TOTAL — use --all to see all)"
                                        fi
                                        echo ""
                                      fi

                                      # Gap lists
                                      UNMAINT_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                      ),
                                      closure_pkgs AS (
                                        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                      )
                                      SELECT count(*) FROM closure_pkgs WHERE len(maintainers) = 0;" \
                                        | ${duckdb} -readonly "$DB" | tr -d '[:space:]')

                                      if [ "$UNMAINT_TOTAL" != "0" ]; then
                                        echo "=== Unmaintained packages ==="
                                        query "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT attr AS package, version, $DESCFN
                                        FROM closure_pkgs p
                                        WHERE len(maintainers) = 0
                                        ORDER BY attr $LIMIT;"
                                        if [ "$ALL" != 1 ] && [ "$UNMAINT_TOTAL" -gt 25 ]; then
                                          echo "(showing 25 of $UNMAINT_TOTAL — use --all to see all)"
                                        fi
                                        echo ""
                                      fi

                                      if [ "$HAS_PASSTHRU" = 1 ]; then
                                        NOTEST_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_tests IS NULL OR pt.has_tests = false;" \
                                          | ${duckdb} -readonly "$DB" | tr -d '[:space:]')

                                        if [ "$NOTEST_TOTAL" != "0" ]; then
                                          echo "=== Packages without tests ==="
                                          query "WITH closure AS (
                                            SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                          ),
                                          closure_pkgs AS (
                                            SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                          )
                                          SELECT cp.attr AS package, cp.version, $DESCFN
                                          FROM closure_pkgs cp
                                          LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                          WHERE pt.has_tests IS NULL OR pt.has_tests = false
                                          ORDER BY cp.attr $LIMIT;"
                                          if [ "$ALL" != 1 ] && [ "$NOTEST_TOTAL" -gt 25 ]; then
                                            echo "(showing 25 of $NOTEST_TOTAL — use --all to see all)"
                                          fi
                                          echo ""
                                        fi

                                        NOUPD_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
                                          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                        ),
                                        closure_pkgs AS (
                                          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                        )
                                        SELECT count(*) FROM closure_pkgs cp
                                        LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                        WHERE pt.has_update_script IS NULL OR pt.has_update_script = false;" \
                                          | ${duckdb} -readonly "$DB" | tr -d '[:space:]')

                                        if [ "$NOUPD_TOTAL" != "0" ]; then
                                          echo "=== Packages without update scripts ==="
                                          query "WITH closure AS (
                                            SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
                                          ),
                                          closure_pkgs AS (
                                            SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
                                          )
                                          SELECT cp.attr AS package, cp.version, $DESCFN
                                          FROM closure_pkgs cp
                                          LEFT JOIN package_passthru pt ON cp.attr = pt.attr
                                          WHERE pt.has_update_script IS NULL OR pt.has_update_script = false
                                          ORDER BY cp.attr $LIMIT;"
                                          if [ "$ALL" != 1 ] && [ "$NOUPD_TOTAL" -gt 25 ]; then
                                            echo "(showing 25 of $NOUPD_TOTAL — use --all to see all)"
                                          fi
                                          echo ""
                                        fi
                                      fi
                                    fi
                                    ;;

                                  stats)
                                    if [ "$NDJSON" = 1 ]; then
                                      # File info as NDJSON
                                      BASE_SIZE="null"; BASE_EXISTS="false"
                                      if [ -f "${base-db}" ]; then
                                        BASE_SIZE="\"$(du -h "${base-db}" | cut -f1)\""
                                        BASE_EXISTS="true"
                                      fi
                                      ENRICHED_SIZE="null"; ENRICHED_EXISTS="false"; ENRICHED_STALE="false"
                                      if [ -f "${enriched-db}" ]; then
                                        ENRICHED_SIZE="\"$(du -h "${enriched-db}" | cut -f1)\""
                                        ENRICHED_EXISTS="true"
                                        if [ "${base-db}" -nt "${enriched-db}" ]; then
                                          ENRICHED_STALE="true"
                                        fi
                                      fi
                                      ${jq} -cn --arg bp "${base-db}" --argjson bs "$BASE_SIZE" --argjson be "$BASE_EXISTS" \
                                              --arg ep "${enriched-db}" --argjson es "$ENRICHED_SIZE" --argjson ee "$ENRICHED_EXISTS" --argjson est "$ENRICHED_STALE" \
                                        '{type:"database_file",path:$bp,size:$bs,exists:$be}'
                                      ${jq} -cn --arg bp "${base-db}" --argjson bs "$BASE_SIZE" --argjson be "$BASE_EXISTS" \
                                              --arg ep "${enriched-db}" --argjson es "$ENRICHED_SIZE" --argjson ee "$ENRICHED_EXISTS" --argjson est "$ENRICHED_STALE" \
                                        '{type:"database_file",path:$ep,size:$es,exists:$ee,stale:$est}'
                                      # Table counts as NDJSON
                                      printf '.mode json\n%s\n' \
                                        "SELECT 'packages' AS tbl, count(*) AS rows FROM packages
                                         UNION ALL SELECT 'package_maintainers', count(*) FROM package_maintainers
                                         UNION ALL SELECT 'package_platforms', count(*) FROM package_platforms;" \
                                        | ${duckdb} -readonly "$DB" | ${jq} -c '.[]'
                                      if ${duckdb} -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
                                        printf '.mode json\n%s\n' \
                                          "SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
                                           UNION ALL SELECT 'package_passthru', count(*) FROM package_passthru;" \
                                          | ${duckdb} -readonly "$DB" | ${jq} -c '.[]'
                                      fi
                                    elif [ "$CSV" = 1 ]; then
                                      echo "base_db,${base-db}"
                                      echo "enriched_db,${enriched-db}"
                                      printf '.mode csv\n%s\n' \
                                        "SELECT 'packages' AS tbl, count(*) AS rows FROM packages
                                         UNION ALL SELECT 'package_maintainers', count(*) FROM package_maintainers
                                         UNION ALL SELECT 'package_platforms', count(*) FROM package_platforms;" \
                                        | ${duckdb} -readonly "$DB"
                                      if ${duckdb} -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
                                        printf '.mode csv\n%s\n' \
                                          "SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
                                           UNION ALL SELECT 'package_passthru', count(*) FROM package_passthru;" \
                                          | ${duckdb} -readonly "$DB"
                                      else
                                        echo "(enriched tables not available)"
                                      fi
                                    else
                                      echo "=== Database files ==="
                                      printf "  Base DB:     %s\n" "${base-db}"
                                      if [ -f "${base-db}" ]; then
                                        SIZE=$(du -h "${base-db}" | cut -f1)
                                        printf "               %s\n" "$SIZE"
                                      else
                                        printf "               (not found)\n"
                                      fi
                                      printf "  Enriched DB: %s\n" "${enriched-db}"
                                      if [ -f "${enriched-db}" ]; then
                                        SIZE=$(du -h "${enriched-db}" | cut -f1)
                                        printf "               %s\n" "$SIZE"
                                        if [ "${base-db}" -nt "${enriched-db}" ]; then
                                          printf "               (stale — base DB is newer)\n"
                                        fi
                                      else
                                        printf "               (not found)\n"
                                      fi
                                      echo ""
                                      echo "=== Table row counts ==="
                                      ${duckdb} -readonly "$DB" <<'STATS_SQL'
                .mode table
                                        SELECT 'packages' AS tbl, count(*) AS rows FROM packages
                                        UNION ALL
                                        SELECT 'package_maintainers', count(*) FROM package_maintainers
                                        UNION ALL
                                        SELECT 'package_platforms', count(*) FROM package_platforms;
                STATS_SQL
                                      if ${duckdb} -readonly "$DB" -c "SELECT 1 FROM dependency_edges LIMIT 1" >/dev/null 2>&1; then
                                        ${duckdb} -readonly "$DB" <<'STATS_SQL'
                .mode table
                                          SELECT 'dependency_edges' AS tbl, count(*) AS rows FROM dependency_edges
                                          UNION ALL
                                          SELECT 'package_passthru', count(*) FROM package_passthru;
                STATS_SQL
                                      else
                                        echo "(enriched tables not available)"
                                      fi
                                    fi
                                    ;;

                                  db)
                                    exec ${duckdb} -readonly "$DB" "''${ARGS[@]:1}"
                                    ;;

                                  help|--help|-h)
                                    usage
                                    ;;

                                  *)
                                    echo "Unknown command: $CMD" >&2
                                    usage >&2
                                    exit 1
                                    ;;
                                esac
              '')
            ];

            shellHook = ''
              if [ -z "''${NIX_FACTS_QUIET:-}" ]; then
                echo ""
                echo "=== nix-facts ==="
                echo "Query Nixpkgs metadata from a local DuckDB database."
                echo ""

                # DB stats
                PKG_COUNT=$(${pkgs.duckdb}/bin/duckdb -readonly -noheader -csv "${base-db}" "SELECT count(*) FROM packages;" 2>/dev/null || echo "?")
                echo "Database: $PKG_COUNT packages loaded"
                echo ""

                # Available commands
                echo "Commands (base):"
                echo "  search <term>        Search packages by name/description"
                echo "  info <attr>          Show all metadata for a package"
                echo "  maintainers <attr>   Maintainers of a package"
                echo "  maintainer <github>  Packages by maintainer"
                echo "  top-maintainers      Top maintainers by package count"
                echo "  orphans              Packages with no maintainers"
                echo "  broken               Packages marked as broken"
                echo "  unfree               Packages marked as unfree"
                echo "  platforms <attr>     Supported platforms for a package"
                echo "  audit [target]       Health audit of a runtime closure"
                echo "  stats                Database sizes and row counts"
                echo "  db [args...]         Raw DuckDB session"
                echo ""
                echo "Commands (requires enrich):"
                echo "  deps <attr>          Transitive dependencies"
                echo "  direct-deps <attr>   Dependencies to given depth"
                echo "  dep-maintainers <attr>  Maintainers of transitive deps"
                echo "  no-tests             Packages without tests"
                echo "  no-update-script     Packages without update scripts"
                echo ""

                # Enrichment status
                if [ -f "${enriched-db}" ]; then
                  if [ "${base-db}" -nt "${enriched-db}" ]; then
                    echo "Warning: enriched DB may be stale (base DB is newer)."
                    echo "  Run 'nix-facts-enrich' to refresh."
                  else
                    echo "Enriched DB: available"
                  fi
                else
                  echo "Enriched DB: not found"
                  echo "  Run 'nix-facts-enrich' to enable deps/passthru commands."
                fi

                echo ""
                echo "Run 'nix-facts help' for detailed usage."
                echo ""
              fi
            '';
          };
        }
      );
    };
}
