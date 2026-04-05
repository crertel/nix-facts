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

          # Stage 1: Evaluate all of nixpkgs and dump package metadata to NDJSON.
          # Uses nix-eval-jobs with a fake local store so it can instantiate
          # derivations inside the sandbox without requiring sandbox = relaxed.
          meta-json =
            pkgs.runCommand "nixpkgs-meta-ndjson"
              {
                __structuredAttrs = true;
                unsafeDiscardReferences.out = true;
                nativeBuildInputs = [ pkgs.nix-eval-jobs ];
              }
              ''
                                # Set up a fake local store so nix-eval-jobs can instantiate
                                # derivations inside the sandbox without daemon access.
                                export HOME=$PWD
                                export NIX_STATE_DIR=$PWD/nix-state
                                export NIX_DATA_DIR=$PWD/nix-data
                                export NIX_CONF_DIR=$PWD/nix-conf
                                export GC_DONT_GC=1
                                export NIX_CONFIG="experimental-features = flakes nix-command
                store = $PWD/temp"
                                mkdir -p temp

                                mkdir -p $out
                                NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1 \
                                  nix-eval-jobs --meta ${nixpkgs} > $out/meta.ndjson
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
                            jq -c 'select(.error == null) | {
                              attr: .attr,
                              name: .name,
                              pname: (.pname // null),
                              version: (.version // null),
                              drv_path: (.drvPath // null),
                              description: (.meta.description // null),
                              homepage: (
                                (.meta.homepage // null) |
                                if type == "array" then .[0] // null else . end
                              ),
                              position: (.meta.position // null),
                              main_program: (.meta.mainProgram // null),
                              broken: (.meta.broken // false),
                              unfree: (.meta.unfree // false),
                              license: (
                                (.meta.license // null) |
                                if type == "array" then
                                  [.[] | .spdxId // .shortName // .fullName // "unknown"] | join(", ")
                                elif type == "object" then
                                  .spdxId // .shortName // .fullName // "unknown"
                                elif type == "string" then .
                                else null end
                              ),
                              maintainers: [(.meta.maintainers // [])[] | .github // empty]
                            }' ${meta-json}/meta.ndjson > /tmp/packages.ndjson

                            echo ":: Converting to NDJSON (maintainers)..."
                            jq -c 'select(.error == null) |
                              .attr as $attr | .name as $name |
                              (.meta.maintainers // [])[] |
                              {
                                attr: $attr,
                                name: $name,
                                maintainer_name:   (.name // null),
                                maintainer_github: (.github // null),
                                maintainer_email:  (.email // null)
                              }' ${meta-json}/meta.ndjson > /tmp/maintainers.ndjson

                            echo ":: Converting to NDJSON (platforms)..."
                            jq -c 'select(.error == null) |
                              .attr as $attr |
                              (.meta.platforms // [])[] |
                              if type == "string" then
                                {attr: $attr, platform: .}
                              else empty end' ${meta-json}/meta.ndjson > /tmp/platforms.ndjson

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

          nix-facts-cli = pkgs.runCommand "nix-facts-cli" { } ''
            mkdir -p $out/bin $out/lib/nix-facts/cmd

            subst() {
              local src="$1" dst="$2"
              sed \
                -e 's|@jq@|${jq}|g' \
                -e 's|@duckdb@|${duckdb}|g' \
                -e 's|@baseDb@|${base-db}|g' \
                -e 's|@enrichedDb@|${enriched-db}|g' \
                -e 's|@metaJson@|${meta-json}|g' \
                -e 's|@nixpkgs@|${nixpkgs}|g' \
                -e "s|@libDir@|$out/lib/nix-facts|g" \
                "$src" > "$dst"
            }

            subst ${./scripts/nix-facts.sh} $out/bin/nix-facts
            chmod +x $out/bin/nix-facts

            subst ${./scripts/nix-facts-enrich.sh} $out/bin/nix-facts-enrich
            sed -i '1i#!/usr/bin/env bash' $out/bin/nix-facts-enrich
            chmod +x $out/bin/nix-facts-enrich

            subst ${./scripts/lib.sh} $out/lib/nix-facts/lib.sh

            for cmd in ${./scripts/cmd}/*.sh; do
              subst "$cmd" "$out/lib/nix-facts/cmd/$(basename "$cmd")"
            done
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.duckdb
              pkgs.jq
              nix-facts-cli
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
                echo "  audit-system         Health audit of the running NixOS system"
                echo "  audit-devshell <ref> Health audit of a flake's dev shell closure"
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
