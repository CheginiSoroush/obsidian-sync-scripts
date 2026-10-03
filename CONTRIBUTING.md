# Contributing to ob-sync

First off — thanks for caring enough to open this file.

## Repository layout

```text
bin/ob-sync            The entire product: one platform-aware Bash script
mobile/install.sh      Termux installer
desktop/install.sh     Linux / macOS installer
docs/                  Troubleshooting and deep-dive documentation
.github/workflows/     CI (ShellCheck gate)
```

`bin/ob-sync` is the single source of truth. **Never** fork it per platform —
platform differences belong behind the portability helpers inside the script.

## Development loop

1. Make your change in `bin/ob-sync` (or the installers).
2. Lint locally:

   ```bash
   shellcheck -x -S warning bin/ob-sync mobile/install.sh desktop/install.sh
   ```

3. Smoke-test on a real device or machine:

   ```bash
   ob-sync doctor && ob-sync health && ob-sync quick
   ```

4. Commit with a [Conventional Commits](https://www.conventionalcommits.org/)
   message, e.g. `fix: prune now orders backups by embedded timestamp`.

## Hard rules (CI enforces the lintable ones)

- **Bash 4+ only — but no GNU-only flags.** macOS ships BSD userland: no
  `stat -c`, no `du --exclude`, no `xargs -r`. Use the portability helpers.
- **Quote every expansion.** Filenames in a vault are arbitrary.
- **Null-delimited file lists.** `find -print0` / `read -d ''` — never
  newline-delimited pipelines over paths.
- **No `set -e`.** Every failure path returns explicitly with a user-facing
  message; the interactive menu must survive errors.
- **Fail-closed on untrusted input.** Anything that reads an archive or a
  user-supplied path is audited before it is trusted.
- **Atomic writes.** Temp file + rename, always.

## Pull request checklist

- [ ] `shellcheck -S warning` passes locally
- [ ] Tested on Termux **or** desktop (ideally both, for platform-sensitive changes)
- [ ] Help text and docs updated if behavior changed
- [ ] Changelog entry added under the next version heading
- [ ] After any conflicted rebase: `grep -cE "^(<<<<<<< |=======$|>>>>>>> )" **/*.md` returns 0 before committing
