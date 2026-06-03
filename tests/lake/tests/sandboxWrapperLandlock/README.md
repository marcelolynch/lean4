# Landlock sandbox-as-wrapper POC (`LAKE_WRAPPED_EXEC`)

A working proof that the per-module write isolation of the `lake build --sandbox`
PR (#13940) can be achieved **entirely outside Lean and Lake**, as an external
wrapper plugged into the `LAKE_WRAPPED_EXEC` hook (#13948) — with **no changes
to the compiler, build system, or runtime**, and **no sandbox-specific Lake
support** (it rides only the generic execution hook). On Linux it uses Landlock;
it is the counterpart of the macOS/Seatbelt prototype discussed on the PR.

This is the **fully-through-sandbox** design: the wrapper does the whole job —
scratch prep, path translation, and copying outputs back — by itself.

## How it closes the sibling-poisoning vector

The threat: `Foo.Bar`'s build writing `Foo.Baz`'s `.olean`. Landlock grants are
directory-granular, so granting write on the shared output dir to let `lean`
create `Bar.olean` would also permit clobbering `Baz.olean`. The wrapper avoids
ever granting that dir:

1. It makes a **private per-job scratch dir** and redirects every declared
   output into it. The manifest carries both `args` (with output paths after
   `-o/-i/-c/-b`) and `outputs` (the same strings), so `outputs ∩ args` is the
   path-translation table — no flag parsing, no Lake involvement:

   ```
   out_set  = set(manifest["outputs"])
   new_args = [ scratch/basename(a) if a in out_set else a  for a in args ]
   ```

2. It runs `lean` under a **write-only Landlock policy** confined to the scratch
   dir (reads/exec unrestricted), via the standalone `landlock-exec` helper.
3. It **relocates** each `scratch/<basename>` to its real path, refusing
   anything that is not a regular file (symlink/FIFO/...).

Because the scratch dir is private to the job, the directory-granular Landlock
grant on it is safe by construction: no sibling module's `.olean` lives there.

## Files

- `Test/A.lean`, `Test/B.lean` — the attack: `B`'s elaboration tries to
  overwrite the sibling `Test/A.olean`.
- `landlock-exec.c` — standalone, freestanding port of the write-only Landlock
  policy (closes inherited fds, requires ABI ≥ 3, grants writes only beneath
  each `--rw` dir, runs the child in its own killed-afterwards process group).
- `sandbox-wrapper` — the `LAKE_WRAPPED_EXEC` wrapper (scratch + translation +
  `landlock-exec` + relocate/validate).
- `test.sh` — the end-to-end test (real `lake`+`lean`; SKIPs off Linux or where
  Landlock is unavailable).
- `verify.sh` — convenience: build the branch and run `test.sh` in a Linux
  container.

## Running

```sh
# On Linux (kernel >= 6.2), within a built lean4 checkout:
tests/lake/run_test.sh sandboxWrapperLandlock

# From macOS (or to reproduce hermetically), via a container:
tests/lake/tests/sandboxWrapperLandlock/verify.sh
```

Note: under Docker, pass `--security-opt seccomp=unconfined` so the runtime's
seccomp filter does not block the `landlock_*` syscalls (verify.sh does this).
