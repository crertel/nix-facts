if [ "$CMD" = "audit-system" ]; then
      if [ -e /run/current-system ]; then
        STORE_PATH="/run/current-system"
        progress "Auditing current running system..."
      else
        echo "ERROR: /run/current-system not found (not NixOS?)." >&2
        exit 1
      fi
    else
      AUDIT_TARGET="${ARGS[1]:-}"
      if [ -z "$AUDIT_TARGET" ]; then
        echo "Usage: nix-facts audit-devshell <flake-ref>" >&2
        echo "Examples:" >&2
        echo "  nix-facts audit-devshell ." >&2
        echo "  nix-facts audit-devshell ./flake.nix" >&2
        echo "  nix-facts audit-devshell github:user/repo" >&2
        exit 1
      fi

      # Resolve to a flake directory
      if [[ "$AUDIT_TARGET" == *.nix ]] && [ -f "$AUDIT_TARGET" ]; then
        FLAKE_DIR="$(dirname "$(realpath "$AUDIT_TARGET")")"
      elif [ -d "$AUDIT_TARGET" ]; then
        FLAKE_DIR="$(realpath "$AUDIT_TARGET")"
      else
        FLAKE_DIR="$AUDIT_TARGET"
      fi

      SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
      FLAKE_REF="$FLAKE_DIR#devShells.$SYSTEM.default"
      progress "Building $FLAKE_REF..."
      if ! STORE_PATH=$(nix build --no-link --print-out-paths "$FLAKE_REF"); then
        echo "ERROR: nix build failed for $FLAKE_REF" >&2
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
      | sort -u | @jq@ -Rc '{name: .}' > "$AUDIT_TMP/closure_names.ndjson"
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
    if @duckdb@ -readonly "$DB" -c "SELECT 1 FROM package_passthru LIMIT 1" >/dev/null 2>&1; then
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
          printf('%.1f%%', 100.0 * (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true) / NULLIF(count(*), 0)) AS update_script_pct,
          count(CASE WHEN broken THEN 1 END) AS broken_count,
          printf('%.1f%%', 100.0 * count(CASE WHEN broken THEN 1 END) / NULLIF(count(*), 0)) AS broken_pct,
          count(CASE WHEN unfree THEN 1 END) AS unfree_count,
          printf('%.1f%%', 100.0 * count(CASE WHEN unfree THEN 1 END) / NULLIF(count(*), 0)) AS unfree_pct
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
          printf('%.1f%%', 100.0 * count(CASE WHEN len(maintainers) > 0 THEN 1 END) / NULLIF(count(*), 0)) AS maintainer_pct,
          count(CASE WHEN broken THEN 1 END) AS broken_count,
          printf('%.1f%%', 100.0 * count(CASE WHEN broken THEN 1 END) / NULLIF(count(*), 0)) AS broken_pct,
          count(CASE WHEN unfree THEN 1 END) AS unfree_count,
          printf('%.1f%%', 100.0 * count(CASE WHEN unfree THEN 1 END) / NULLIF(count(*), 0)) AS unfree_pct
        FROM closure_pkgs;"
      fi
      printf '.mode json\n%s\n' "$SUMMARY_SQL" \
        | @duckdb@ -readonly "$DB" \
        | @jq@ -c '.[] + {type: "summary", store_path: "'"$STORE_PATH"'", closure_size: '"$CLOSURE_SIZE"'}'

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
        | @duckdb@ -readonly "$DB" \
        | @jq@ -c '.[] + {type: "maintainer"}'

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
        | @duckdb@ -readonly "$DB" \
        | @jq@ -c '.[] + {type: "unmaintained"}'

      # Broken packages
      printf '.mode json\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT attr AS package, version FROM closure_pkgs
      WHERE broken = true
      ORDER BY attr;" \
        | @duckdb@ -readonly "$DB" \
        | @jq@ -c '.[] + {type: "broken"}'

      # Unfree packages
      printf '.mode json\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT attr AS package, version FROM closure_pkgs
      WHERE unfree = true
      ORDER BY attr;" \
        | @duckdb@ -readonly "$DB" \
        | @jq@ -c '.[] + {type: "unfree"}'

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
          | @duckdb@ -readonly "$DB" \
          | @jq@ -c '.[] + {type: "no_tests"}'

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
          | @duckdb@ -readonly "$DB" \
          | @jq@ -c '.[] + {type: "no_update_script"}'
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
          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true) AS with_update_script,
          count(CASE WHEN broken THEN 1 END) AS broken,
          count(CASE WHEN unfree THEN 1 END) AS unfree
        FROM closure_pkgs;"
      else
        SUMMARY_SQL="WITH closure AS (
          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
        ),
        closure_pkgs AS (
          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
        )
        SELECT count(*) AS matched,
          count(CASE WHEN len(maintainers) > 0 THEN 1 END) AS with_maintainers,
          count(CASE WHEN broken THEN 1 END) AS broken,
          count(CASE WHEN unfree THEN 1 END) AS unfree
        FROM closure_pkgs;"
      fi
      if [ "$HAS_PASSTHRU" = 1 ]; then
        printf '.mode csv\n.headers off\n%s\n' "$SUMMARY_SQL" \
          | @duckdb@ -readonly "$DB" \
          | tr -d '\r' \
          | while IFS=, read -r matched maintainers tests update_script broken unfree rest; do
              echo "matched_packages,$matched"
              echo "with_maintainers,$maintainers"
              echo "with_tests,$tests"
              echo "with_update_script,$update_script"
              echo "broken,$broken"
              echo "unfree,$unfree"
            done
      else
        printf '.mode csv\n.headers off\n%s\n' "$SUMMARY_SQL" \
          | @duckdb@ -readonly "$DB" \
          | tr -d '\r' \
          | while IFS=, read -r matched maintainers broken unfree rest; do
              echo "matched_packages,$matched"
              echo "with_maintainers,$maintainers"
              echo "broken,$broken"
              echo "unfree,$unfree"
            done
      fi
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
        | @duckdb@ -readonly "$DB"
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
        | @duckdb@ -readonly "$DB"

      printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT 'broken', attr, version FROM closure_pkgs
      WHERE broken = true
      ORDER BY attr;" \
        | @duckdb@ -readonly "$DB"

      printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT 'unfree', attr, version FROM closure_pkgs
      WHERE unfree = true
      ORDER BY attr;" \
        | @duckdb@ -readonly "$DB"

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
          | @duckdb@ -readonly "$DB"

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
          | @duckdb@ -readonly "$DB"
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
        | @duckdb@ -readonly "$DB" | tr -d '[:space:]')
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
          (SELECT count(*) FROM closure_pkgs cp2 LEFT JOIN package_passthru pt ON cp2.attr = pt.attr WHERE pt.has_update_script = true),
          count(CASE WHEN broken THEN 1 END),
          count(CASE WHEN unfree THEN 1 END)
        FROM closure_pkgs;" \
          | @duckdb@ -readonly "$DB" \
          | tr -d '\r' \
          | while IFS=, read -r maint total tests upd broken unfree; do
              printf "  Maintainers:     %s / %s (%s%%)\n" "$maint" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $maint / $total}")"
              printf "  Tests:           %s / %s (%s%%)\n" "$tests" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $tests / $total}")"
              printf "  Update scripts:  %s / %s (%s%%)\n" "$upd" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $upd / $total}")"
              printf "  Broken:          %s / %s (%s%%)\n" "$broken" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $broken / $total}")"
              printf "  Unfree:          %s / %s (%s%%)\n" "$unfree" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $unfree / $total}")"
            done
      else
        printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
        ),
        closure_pkgs AS (
          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
        )
        SELECT count(CASE WHEN len(maintainers) > 0 THEN 1 END), count(*),
          count(CASE WHEN broken THEN 1 END),
          count(CASE WHEN unfree THEN 1 END)
        FROM closure_pkgs;" \
          | @duckdb@ -readonly "$DB" \
          | tr -d '\r' \
          | while IFS=, read -r maint total broken unfree; do
              printf "  Maintainers:     %s / %s (%s%%)\n" "$maint" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $maint / $total}")"
              printf "  Broken:          %s / %s (%s%%)\n" "$broken" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $broken / $total}")"
              printf "  Unfree:          %s / %s (%s%%)\n" "$unfree" "$total" "$(awk "BEGIN {printf \"%.1f\", 100.0 * $unfree / $total}")"
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
        | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

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
        | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

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

      BROKEN_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT count(*) FROM closure_pkgs WHERE broken = true;" \
        | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

      if [ "$BROKEN_TOTAL" != "0" ]; then
        echo "=== Broken packages ==="
        query "WITH closure AS (
          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
        ),
        closure_pkgs AS (
          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
        )
        SELECT attr AS package, version, $DESCFN
        FROM closure_pkgs p
        WHERE broken = true
        ORDER BY attr $LIMIT;"
        if [ "$ALL" != 1 ] && [ "$BROKEN_TOTAL" -gt 25 ]; then
          echo "(showing 25 of $BROKEN_TOTAL — use --all to see all)"
        fi
        echo ""
      fi

      UNFREE_TOTAL=$(printf '.mode csv\n.headers off\n%s\n' "WITH closure AS (
        SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
      ),
      closure_pkgs AS (
        SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
      )
      SELECT count(*) FROM closure_pkgs WHERE unfree = true;" \
        | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

      if [ "$UNFREE_TOTAL" != "0" ]; then
        echo "=== Unfree packages ==="
        query "WITH closure AS (
          SELECT DISTINCT name FROM read_ndjson_auto('$CLOSURE_NDJSON')
        ),
        closure_pkgs AS (
          SELECT p.* FROM closure c JOIN packages p ON c.name = p.name
        )
        SELECT attr AS package, version, $DESCFN
        FROM closure_pkgs p
        WHERE unfree = true
        ORDER BY attr $LIMIT;"
        if [ "$ALL" != 1 ] && [ "$UNFREE_TOTAL" -gt 25 ]; then
          echo "(showing 25 of $UNFREE_TOTAL — use --all to see all)"
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
          | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

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
          | @duckdb@ -readonly "$DB" | tr -d '[:space:]')

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
