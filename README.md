# nix-facts

> [!NOTE]
> **This project is built in collaboration with [Claude](https://claude.ai), Anthropic's AI assistant.**
> Large portions of the code, documentation, and tooling were written by or with Claude.

Queryable DuckDB database of nixpkgs package metadata.

Evaluates all of nixpkgs, extracts package metadata (names, versions, licenses,
maintainers, platforms), and loads it into a local DuckDB database you can query
with simple CLI commands or raw SQL.

## Quick start

```bash
# From a local checkout
nix develop

# Or directly from GitHub, no checkout needed
nix develop github:crertel/nix-facts
```

Once inside the dev shell, run `nix-facts help` to see available commands.

## Commands

| Command | Description |
|---|---|
| `search <term>` | Search packages by name or description |
| `info <attr>` | Show all metadata for a single package |
| `maintainers <attr>` | List maintainers of a package |
| `maintainer <github>` | List packages by maintainer GitHub handle |
| `top-maintainers` | Top maintainers by package count |
| `orphans` | Packages with no maintainers |
| `broken` | Packages marked as broken |
| `unfree` | Packages marked as unfree |
| `platforms <attr>` | Supported platforms for a package |
| `audit [target]` | Health audit of a runtime closure |
| `stats` | Database sizes and row counts |
| `db [args...]` | Open a raw DuckDB session |

### Commands requiring enrichment

These commands require running `nix-facts-enrich` first (see below):

| Command | Description |
|---|---|
| `deps <attr>` | Transitive dependencies of a package |
| `direct-deps <attr> [depth]` | Dependencies to a given depth |
| `dep-maintainers <attr>` | Maintainers across transitive deps |
| `no-tests` | Packages without tests |
| `no-update-script` | Packages without update scripts |

### Closure audit

The `audit` command cross-references a Nix closure's runtime dependencies against
the nix-facts database, reporting maintainer coverage, test coverage, and update
script coverage.

```bash
nix-facts audit                              # current running NixOS system
nix-facts audit .#nixosConfigurations.myhost  # flake reference
nix-facts audit ./shell.nix                  # .nix file
nix-facts audit /nix/store/...-system        # store path directly
```

Without enrichment, only maintainer coverage is shown. Run `nix-facts-enrich` to
enable test and update script metrics.

## Output formats

All query commands accept these flags:

- `--csv` — Output as CSV
- `--ndjson` — Output as newline-delimited JSON (one object per line)
- `--all` — Show full results with no row limits or description truncation
- `--quiet` / `-q` — Suppress progress messages on stderr

Without flags, output is rendered as a table.

## Enrichment

The base database contains package metadata only. To unlock dependency and
passthru queries, run the enrichment pipeline:

```bash
nix-facts-enrich
```

This evaluates nixpkgs derivations to extract dependency edges and passthru
metadata (tests, update scripts). It takes several minutes and requires a
working Nix daemon. The enriched database is stored at
`~/.cache/nix-facts/meta.db`.

## Contributing

1. Fork the repo and create a feature branch
2. Make your changes
3. Run `nix fmt` before submitting
4. Open a pull request against `master`

We use squash merges. Please keep PRs focused on a single change.

### AI contributions

AI-generated contributions are welcome. All contributions (AI or otherwise) must
follow the same rules: code must work, pass CI, and follow project conventions.
AI involvement must be disclosed — either directly in the PR description or by
adding the AI as a co-author on commits (e.g.,
`Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`).
