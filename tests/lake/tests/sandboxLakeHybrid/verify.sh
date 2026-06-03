#!/usr/bin/env bash
# Convenience harness to run this test inside a Linux container (Landlock is
# Linux-only, so `test.sh` SKIPs on macOS). Builds the branch's lean+lake from
# the mounted repo, then runs the test via the standard Lake test runner.
#
# Usage (from a checkout of this branch, with Docker running a Linux >= 6.2 VM):
#   tests/lake/tests/sandboxLakeHybrid/verify.sh
#
# `--security-opt seccomp=unconfined` is passed so Docker's seccomp filter does
# not block the landlock_* syscalls.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
echo "## docker kernel: $(docker info --format '{{.KernelVersion}}')"

docker run --rm --security-opt seccomp=unconfined \
  -v "$REPO_ROOT":/lean4:ro -w /work ubuntu:24.04 bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git libgmp-dev libuv1-dev cmake ccache clang pkgconf g++ python3 rsync >/dev/null
  rsync -a --delete --exclude "/.git" --exclude "/build" --exclude ".lake" /lean4/ /work/
  cd /work
  cmake --preset release >/dev/null
  make -C build/release -j"$(nproc)"
  export LAKE=/work/build/release/stage1/bin/lake
  export PATH=/work/build/release/stage1/bin:$PATH
  cd tests/lake
  ./run_test.sh tests/sandboxLakeHybrid
'
