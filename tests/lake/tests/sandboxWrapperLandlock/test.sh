source ../common.sh

# End-to-end test for the Landlock `LAKE_WRAPPED_EXEC` sandbox wrapper.
#
# Demonstrates that the per-module write isolation of the `lake build --sandbox`
# PR (#13940) can be achieved entirely outside Lean and Lake, as an external
# wrapper plugged into the `LAKE_WRAPPED_EXEC` hook -- no changes to the
# compiler, build system, or runtime, and no sandbox-specific Lake support (it
# rides only the generic execution hook).
#
# `Test/B.lean`'s elaboration tries to overwrite the sibling `Test/A.olean`
# (the PR's exact cache-poisoning threat). Under the wrapper the kernel denies
# that write while the build still produces correct artifacts.
#
# Landlock is Linux-only and needs a recent kernel (ABI >= 3, Linux 6.2). Off
# Linux, or where Landlock/syscalls are unavailable, the test SKIPs.

HERE="$(pwd)"
WRAPPER="$HERE/sandbox-wrapper"
export LANDLOCK_EXEC="$HERE/landlock-exec"
OLEAN=".lake/build/lib/lean/Test/A.olean"

if [ "$UNAME" != Linux ]; then
  echo "SKIP: Landlock is Linux-only (uname=$UNAME)"
  exit 0
fi

# Build the standalone Landlock helper (skip if no C++ compiler is available).
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

# Probe Landlock availability (ABI >= 3); skip on old kernels or blocked syscalls.
if ! "$LANDLOCK_EXEC" --rw "$HERE" -- true 2>probe.err; then
  echo "SKIP: Landlock unavailable: $(cat probe.err)"
  rm -f probe.err "$LANDLOCK_EXEC"
  exit 0
fi
rm -f probe.err

clean() { rm -rf .lake; }

echo "# 1. threat: without the wrapper, building Test.B poisons Test.A's olean"
clean
test_run build Test.A
test_run build Test.B
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "OK: A.olean poisoned without the wrapper (threat reproduced)"
else
  echo "FAILURE: expected A.olean to be poisoned without the wrapper"
  exit 1
fi

echo "# 2. defense: with the wrapper, B's write to A.olean is denied by Landlock"
clean
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build Test.A
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build Test.B
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "FAILURE: A.olean was poisoned despite the wrapper"
  exit 1
fi
echo "OK: A.olean intact under the wrapper"

echo "# 3. sanity: a clean wrapped build still produces a usable olean"
clean
LAKE_WRAPPED_EXEC="$WRAPPER" test_run build Test.A Test.B
if [ ! -s "$OLEAN" ]; then
  echo "FAILURE: A.olean missing after sandboxed build"
  exit 1
fi
if grep -qa "POISONED-BY-B" "$OLEAN"; then
  echo "FAILURE: A.olean poisoned in clean sandboxed build"
  exit 1
fi
echo "OK: clean sandboxed build produced a usable A.olean"

clean
rm -f "$LANDLOCK_EXEC" produced.out
echo "PASS"
