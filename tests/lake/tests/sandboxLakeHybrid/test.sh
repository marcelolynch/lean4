source ../common.sh

# End-to-end test for the HYBRID sandbox: `lake build --sandbox` prepares a
# private per-module scratch dir, redirects each module's outputs into it, and
# relocates them back afterwards (validating them as regular files) -- while the
# sandboxed execution is decoupled through the external `$LAKE_WRAPPED_EXEC`
# executor. Lake owns build-tree integrity; the wrapper owns OS write
# confinement (here, Landlock via the standalone `landlock-exec` helper).
#
# `Test/B.lean`'s elaboration tries to overwrite the sibling `Test/A.olean`
# (the cache-poisoning threat of #13940).
#
# The two halves are orthogonal: `lake build --sandbox` with NO wrapper produces
# an identical, working build with zero isolation (step 2 below). The wrapper is
# the sole enforcer; the scratch dir merely makes a write-confining wrapper
# viable and safe.
#
# Landlock is Linux-only (ABI >= 3, Linux 6.2); the test SKIPs elsewhere.

HERE="$(pwd)"
WRAPPER="$HERE/sandbox-wrapper-hybrid"
export LANDLOCK_EXEC="$HERE/landlock-exec"
OLEAN=".lake/build/lib/lean/Test/A.olean"

if [ "$UNAME" != Linux ]; then
  echo "SKIP: Landlock is Linux-only (uname=$UNAME)"
  exit 0
fi

CXX=""
for c in c++ clang++ g++; do
  if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done
if [ -z "$CXX" ]; then
  echo "SKIP: no C++ compiler available to build landlock-exec"
  exit 0
fi
echo "# build landlock-exec with $CXX"
if ! "$CXX" -O2 -o "$LANDLOCK_EXEC" landlock-exec.c; then
  echo "SKIP: could not build landlock-exec"
  exit 0
fi

if ! "$LANDLOCK_EXEC" --rw "$HERE" -- true 2>probe.err; then
  echo "SKIP: Landlock unavailable: $(cat probe.err)"
  rm -f probe.err "$LANDLOCK_EXEC"
  exit 0
fi
rm -f probe.err

clean() { rm -rf .lake; }

echo "# 1. threat: no sandbox, no wrapper -> a sibling module poisons A.olean"
clean
test_run build Test.A
test_run build Test.B
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "OK: A.olean poisoned (threat reproduced)"
else
  echo "FAILURE: expected A.olean to be poisoned"
  exit 1
fi

echo "# 2. lake --sandbox but NO wrapper: redirect/relocate alone does NOT confine"
echo "#    arbitrary writes, so the poison still lands (the wrapper is the enforcer)"
clean
test_run build --sandbox Test.A
test_run build --sandbox Test.B
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "OK: still poisoned without a wrapper (as designed: --sandbox needs a wrapper)"
else
  echo "FAILURE: A.olean unexpectedly intact without a wrapper"
  exit 1
fi

echo "# 3. lake --sandbox + hybrid Landlock wrapper: the sibling write is denied"
clean
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build --sandbox Test.A
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build --sandbox Test.B
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "FAILURE: A.olean poisoned despite the hybrid sandbox"
  exit 1
fi
echo "OK: A.olean intact under the hybrid sandbox"

echo "# 4. sanity: a clean hybrid-sandboxed build still produces a usable olean"
clean
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build --sandbox Test.A Test.B
if [ ! -s "$OLEAN" ]; then
  echo "FAILURE: A.olean missing after hybrid build"
  exit 1
fi
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "FAILURE: A.olean poisoned in clean hybrid build"
  exit 1
fi
echo "OK: clean hybrid-sandboxed build produced a usable A.olean"

clean
rm -f "$LANDLOCK_EXEC" produced.out
echo "PASS"
