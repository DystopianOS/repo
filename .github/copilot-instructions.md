# Copilot instructions for this repository

## Project shape

This repository is an Arch/AUR repository automation hub, not a package source tree. The tracked logic lives in GitHub Actions workflows that:

- validate the bootstrap repo release before accepting new packages
- do not sync packages until `dystopian-keyring` and `dystopian-repo` exist in the bootstrap release
- sign built packages and rebuild the repository database
- notify `Dystopian-PKGBUILDS` when `dystopian-repo` is updated
- clean up workflow artifacts on a schedule

## Workflow architecture

- `on_pkgbuild_version_bump.yml` is the primary publish workflow: it only proceeds after verifying the bootstrap release contains `dystopian-repo`, `dystopian-keyring`, and the repo database, then downloads a built package from `Dystopian-PKGBUILDS`, signs it, updates the repo database, and notifies PKGBUILDS for `dystopian-repo` signature sync.
- `cleanup_repo.yml` is the maintenance workflow that deletes cancelled, failed, and older successful workflow artifacts.

## Commands

No local build, test, or lint scripts are defined in the tracked files. The repository is validated through the GitHub Actions workflows above.

## Conventions to preserve

- Keep workflow job names, step ids, and output names stable; other workflows depend on them.
- Use `actions/create-github-app-token@v3` with the `DYSTOPIANBOT_*` secrets when a GitHub App token is needed.
- Use `fetch-depth: 0` on checkouts when workflows need full history or release/build context.
- Package artifacts and repository database files are staged in `x86_64/`.
- Bash steps use strict mode (`set -euo pipefail`) and should fail fast on missing inputs or secrets.
- Follow the existing remote-action pattern for shared helpers: `DCx7C5/actions/*@v1` instead of copying helper actions into this repo.
- Preserve the existing secret fallback patterns where they already exist, especially for GPG key and passphrase handling.

## Editing guidance

- Treat workflow changes as integration changes: if a step output or dispatch payload changes, update the dependent workflow in the same change.
- Prefer small, explicit bash steps that validate inputs before calling `gh`, `git`, or `makepkg`.
- Keep repository-dispatch and workflow-dispatch payload keys aligned with the current YAML (`package`, `version`, `channel`, `source_sha`, `trigger`, `aur_db_repository`, `package_url`, `package_sha256`, `pkgbuilds_signature_dispatch_type`).
