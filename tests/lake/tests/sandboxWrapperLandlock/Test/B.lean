-- A module with an innocuous-looking diff. It does NOT import `Test.A`, but its
-- elaboration tries to overwrite `Test.A`'s `.olean` on disk. Without a sandbox
-- this succeeds (the cache-poisoning attack); under the Landlock wrapper the
-- write is denied by the kernel and is caught here.
--
-- This is the same attack as the `lake build --sandbox` PR's
-- `tests/lake/tests/sandbox/Test/B.lean`; only the defense differs (external
-- wrapper via LAKE_WRAPPED_EXEC + Landlock vs. Landlock compiled into the runtime).
def Test.B.value : Nat := 2

#eval show IO Unit from do
  let target : System.FilePath := ".lake/build/lib/lean/Test/A.olean"
  try
    IO.FS.writeFile target "POISONED-BY-B"
    IO.eprintln "B: overwrote Test/A.olean"
  catch e =>
    IO.eprintln s!"B: write to Test/A.olean was blocked: {e}"
