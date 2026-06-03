# Hybrid sandbox: `lake build --sandbox` + `LAKE_WRAPPED_EXEC`

A POC, on top of the wrapped-exec hook (#13948), of the **hybrid** split discussed
on #13940: Lake provides a small `--sandbox` mode that prepares a private
per-module scratch directory and moves files around, while the sandboxed
execution is **decoupled through the external `$LAKE_WRAPPED_EXEC` executor**.

- **Lake (`--sandbox`)** owns build-tree integrity: it has the structured
  argument↔output mapping, so it redirects each module's `-o/-i/-c/-b` outputs
  into a private scratch dir and relocates the produced artifacts back into the
  build tree afterwards (validating them as regular files).
- **The wrapper (`sandbox-wrapper-hybrid`)** owns OS write confinement only: it
  Landlock-confines writes to the dirs Lake already redirected into (via the
  standalone `landlock-exec` helper). It does no path translation or relocation.

This reconstructs a chunk of #13940's logic (the scratch/relocate dance), but
routes execution through the external executor instead of a runtime-built-in
Landlock mode. The comments deliberately reflect the design conversation; this
is illustrative, not production-hardened.

## The two halves are orthogonal

`lake build --sandbox` with **no** wrapper produces an identical, working build
with **zero** isolation — the redirect/relocate alone confines nothing (an
arbitrary write to a sibling `.olean` still lands). The wrapper is the sole
enforcer; the scratch dir merely makes a write-confining wrapper viable and safe
(its directory-granular Landlock grant on a *private* dir cannot reach a sibling
module's artifacts). `test.sh` step 2 demonstrates this explicitly.

## Lake side of the change

- `--sandbox` flag (`CLI/Main.lean`, `CLI/Help.lean`)
- `BuildConfig.sandbox` + `getSandbox` (`Build/Context.lean`)
- per-module `sandboxDir?` (`Build/Module.lean`)
- `SandboxDirs` scratch redirect + `relocateSandboxOutput`, with execution routed
  through `runRawProcOrWrapped` (`Build/Actions.lean`)

## Files / running

- `Test/A.lean`, `Test/B.lean` — the attack (`B` overwrites sibling `Test/A.olean`).
- `landlock-exec.c` — standalone write-only Landlock policy helper.
- `sandbox-wrapper-hybrid` — the thin wrapper that only confines writes.
- `test.sh` — end-to-end test (real `lake`+`lean`; SKIPs off Linux / no Landlock).
- `verify.sh` — build the branch and run `test.sh` in a Linux container.

```sh
# On Linux (kernel >= 6.2), within a built lean4 checkout:
tests/lake/run_test.sh tests/sandboxLakeHybrid
# From macOS, hermetically:
tests/lake/tests/sandboxLakeHybrid/verify.sh
```
