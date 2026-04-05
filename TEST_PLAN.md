# Smoke Test Plan

Quick manual smoke test to verify nix-facts commands work after changes.

## Setup

```bash
nix develop
```

## 1. Help

```bash
nix-facts help
```

## 2. Basic queries

```bash
nix-facts search curl
nix-facts info curl
nix-facts maintainers curl
nix-facts maintainer bagrat
nix-facts top-maintainers
nix-facts orphans
nix-facts broken
nix-facts unfree
nix-facts platforms curl
```

## 3. Output formats

```bash
nix-facts search curl --csv
nix-facts search curl --ndjson
nix-facts search curl --quiet
```

## 4. Stats

```bash
nix-facts stats
nix-facts stats --csv
nix-facts stats --ndjson
```

## 5. Raw DB access

```bash
nix-facts db "SELECT count(*) FROM packages;"
```

## 6. Audit

```bash
nix-facts audit-system
nix-facts audit-devshell .
```

## 7. Unknown command (should error)

```bash
nix-facts notacommand
```

## 8. Enrichment (optional, slow)

```bash
nix-facts-enrich
nix-facts deps curl
nix-facts direct-deps curl 2
nix-facts dep-maintainers curl
nix-facts no-tests
nix-facts no-update-script
```
