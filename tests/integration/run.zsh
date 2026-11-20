#!/usr/bin/env zsh
# Runs fettle's SSH integration tests: brings the targets up (idempotent), then runs only the tests
# whose names hold "ssh target" (or the filter given), with FETTLE_INTEGRATION=required so that a
# target that does not answer fails the run rather than being skipped.
#
#   tests/integration/run.zsh [filter]
#
# The targets are left running; `targets.zsh down` and `colima stop fettle` tear them down.

setopt err_exit no_unset pipe_fail

here=${0:A:h}
repo=${here:h:h}

$here/targets.zsh up
cd $repo
FETTLE_INTEGRATION=required avin test . "${1:-ssh target}"
