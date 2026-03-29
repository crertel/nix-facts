{
  description = "Queryable DuckDB database of nixpkgs package metadata";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
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
      packages = eachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Stage 1: Evaluate all of nixpkgs and dump package metadata to JSON.
          # Requires `sandbox = relaxed` in nix.conf because nix-env needs
          # store access to evaluate nixpkgs expressions.
          meta-json = pkgs.runCommand "nixpkgs-meta-json" {
            __noChroot = true;
            nativeBuildInputs = [ pkgs.nix ];
          } ''
            # Preload nixpkgs source into tmpfs so the evaluator reads
            # ~100K small .nix files from RAM instead of random disk I/O.
            WORK=$(mktemp -d --tmpdir nixpkgs-eval.XXXXXXXXXX)
            cp -a ${nixpkgs} "$WORK/nixpkgs"

            mkdir -p $out
            nix-env -f "$WORK/nixpkgs" -qaP --meta --json > $out/meta.json
          '';

          # Stage 2: Convert the JSON dump into a DuckDB database with two tables:
          #   packages            — one row per attribute path
          #   package_maintainers — unnested (attr, maintainer) junction table
          meta-db = pkgs.runCommand "nixpkgs-meta-db" {
            nativeBuildInputs = [ pkgs.duckdb pkgs.jq ];
          } ''
            mkdir -p $out

            echo ":: Converting to NDJSON (packages)..."
            jq -c 'to_entries[] | {
              attr: .key,
              name: .value.name,
              pname: (.value.pname // null),
              version: (.value.version // null),
              description: (.value.meta.description // null),
              homepage: (
                (.value.meta.homepage // null) |
                if type == "array" then .[0] // null else . end
              ),
              position: (.value.meta.position // null),
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
              )
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

            echo ":: Loading into DuckDB..."
            duckdb $out/meta.db <<'SQL'
              CREATE TABLE packages AS
              SELECT * FROM read_ndjson_auto('/tmp/packages.ndjson');

              CREATE TABLE package_maintainers AS
              SELECT * FROM read_ndjson_auto('/tmp/maintainers.ndjson');

              CREATE INDEX idx_maintainer_github
              ON package_maintainers (maintainer_github);
SQL

            echo ":: Done."
            duckdb -readonly $out/meta.db <<'SQL'
              SELECT 'packages' AS tbl, count(*) AS rows FROM packages
              UNION ALL
              SELECT 'maintainers', count(*) FROM package_maintainers;
SQL
          '';
        in
        {
          inherit meta-json meta-db;
          default = meta-db;
        }
      );

      devShells = eachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          meta-db = self.packages.${system}.meta-db;
          db = "${meta-db}/meta.db";
          duckdb = "${pkgs.duckdb}/bin/duckdb";
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.duckdb

              (pkgs.writeShellScriptBin "nix-facts" ''
                set -euo pipefail

                ALL=0
                CSV=0
                ARGS=()
                for arg in "$@"; do
                  case "$arg" in
                    --all) ALL=1 ;;
                    --csv) CSV=1 ;;
                    *) ARGS+=("$arg") ;;
                  esac
                done

                CMD="''${ARGS[0]:-help}"

                query() {
                  if [ "$CSV" = 1 ]; then
                    printf '.mode csv\n%s\n' "$1" | ${duckdb} -readonly "${db}"
                  else
                    printf '.maxrows 100000\n%s\n' "$1" | ${duckdb} -readonly "${db}"
                  fi
                }

                usage() {
                  echo "Usage: nix-facts <command> [options] [args...]"
                  echo ""
                  echo "Commands:"
                  echo "  search <term>         Search packages by name/description"
                  echo "  maintainer <github>   Packages by maintainer GitHub handle"
                  echo "  top-maintainers       Top maintainers by package count"
                  echo "  orphans               Packages with no maintainers"
                  echo "  db [args...]          Raw DuckDB session"
                  echo ""
                  echo "Options:"
                  echo "  --all   Show full results (no row limits or truncation)"
                  echo "  --csv   Output as CSV"
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
                    query "SELECT attr, version, $DESCFN
                FROM packages
                WHERE attr ILIKE '%' || '$ARG' || '%'
                   OR description ILIKE '%' || '$ARG' || '%'
                ORDER BY attr $LIMIT;"
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
                    query "SELECT pm.attr, p.version, $DESCFN
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
                    query "SELECT p.attr, p.version, $DESCFN
                FROM packages p
                LEFT JOIN package_maintainers pm ON p.attr = pm.attr
                WHERE pm.attr IS NULL
                ORDER BY p.attr $LIMIT;"
                    ;;

                  db)
                    exec ${duckdb} -readonly "${db}" "''${ARGS[@]:1}"
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
              echo "nix-facts dev shell"
              echo "Run 'nix-facts help' for usage."
            '';
          };
        }
      );
    };
}
