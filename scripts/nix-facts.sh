#!/usr/bin/env bash
# nix-facts — query nixpkgs metadata from a local DuckDB database.
# This is the main entry point; it sources lib.sh and dispatches to cmd/*.sh.

source @libDir@/lib.sh

case "$CMD" in
  search)           source @libDir@/cmd/search.sh ;;
  info)             source @libDir@/cmd/info.sh ;;
  maintainers)      source @libDir@/cmd/maintainers.sh ;;
  maintainer)       source @libDir@/cmd/maintainer.sh ;;
  top-maintainers)  source @libDir@/cmd/top-maintainers.sh ;;
  orphans)          source @libDir@/cmd/orphans.sh ;;
  broken)           source @libDir@/cmd/broken.sh ;;
  unfree)           source @libDir@/cmd/unfree.sh ;;
  platforms)        source @libDir@/cmd/platforms.sh ;;
  no-tests)         source @libDir@/cmd/no-tests.sh ;;
  no-update-script) source @libDir@/cmd/no-update-script.sh ;;
  deps)             source @libDir@/cmd/deps.sh ;;
  direct-deps)      source @libDir@/cmd/direct-deps.sh ;;
  dep-maintainers)  source @libDir@/cmd/dep-maintainers.sh ;;
  audit-system|audit-devshell) source @libDir@/cmd/audit.sh ;;
  stats)            source @libDir@/cmd/stats.sh ;;
  db)               source @libDir@/cmd/db.sh ;;
  help|--help|-h)   usage ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
