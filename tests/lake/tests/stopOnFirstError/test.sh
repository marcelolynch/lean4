#!/usr/bin/env bash
source ../common.sh

# Tests that --stop-on-first-error causes Lake to exit gracefully after
# the first required build failure rather than waiting for all failures.

./clean.sh

echo "# TEST: --stop-on-first-error exits with failure on broken build"
test_fails build --stop-on-first-error
test_err "Some required targets logged failures" build --stop-on-first-error

./clean.sh

# The slow chain: slowA (3s sleep) and slowB (fetches slowBWork after slowA complete).
# Fail1/Fail2 fail within ~200ms, triggering cancellation long before slowA finishes.
# Expected behavior:
#   - slowA runs to completion (Lake drains in-flight jobs before exiting)
#   - slowBWork is never scheduled (recBuildWithIndex sees cancellation and returns
#     Job.cancelled), so slowB.done is not written
echo "# TEST: cancellation stops dependent jobs from scheduling new work"
test_fails build --stop-on-first-error

if [ ! -f slowA.produced.out ]; then
  echo "FAILURE: slowA.produced.out should exist (slowA ran to completion)"
  exit 1
fi
echo "PASS: slowA.produced.out exists (slowA drained to completion)"

if [ -f slowB.produced.out ]; then
  echo "FAILURE: slowB.produced.out should not exist (slowBWork should have been cancelled)"
  exit 1
fi
echo "PASS: slowB.produced.out does not exist (slowBWork was cancelled)"

./clean.sh

# Module import chain test: SlowChain.A takes ~3s to compile; SlowChain.B imports A.
# Fail1/Fail2 fail within ~200ms, setting the cancellation token long before A finishes.
# Bug: the task chain wired up by recBuildLean (setupJob.mapM callback) runs in JobM
# context and never checks the cancellation token. Once A succeeds (3s later), the
# chain fires and compiles B even though cancellation was already active.
# Expected: SlowChain.B should NOT be compiled after cancellation.
echo "# TEST: cancellation token is checked in module import task chains"
test_fails build --stop-on-first-error

if [ -f ".lake/build/lib/lean/SlowChain/B.olean" ]; then
  echo "FAILURE: SlowChain/B.olean exists -- downstream module was compiled after cancellation"
  echo "         (bug: mapM callbacks in recBuildLean bypass the cancellation token)"
  exit 1
fi
echo "PASS: SlowChain/B.olean does not exist (downstream module skipped after cancellation)"
