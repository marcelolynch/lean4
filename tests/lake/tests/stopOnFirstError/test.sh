#!/usr/bin/env bash
source ../common.sh

# Tests that --stop-on-first-error causes Lake to exit gracefully after
# the first required build failure rather than waiting for all failures.

./clean.sh

# --stop-on-first-error should fail (exit code 1) when build errors are present
echo "# TEST: --stop-on-first-error exits with failure on broken build"
test_fails build --stop-on-first-error
test_err "Some required targets logged failures" build --stop-on-first-error
