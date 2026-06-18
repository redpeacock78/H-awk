# SPDX-License-Identifier: MIT
# dsl/strict_stubs.awk -- Minimal stub definitions for --strict gawk syntax check.
#
# The desugared hawk app references hawk::dispatch and ctx::dispatch which are
# defined in the hawk runtime (hawk.awk + core/). This file provides no-op stubs
# so gawk can validate AWK syntax without needing the full runtime.

@namespace "hawk"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"

@namespace "ctx"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"

@namespace "safe"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"

@namespace "env"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"
