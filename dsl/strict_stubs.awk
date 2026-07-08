# SPDX-License-Identifier: MIT
# dsl/strict_stubs.awk -- Minimal stub definitions for --strict gawk syntax check.
#
# The desugared v2 app references <ns>::dispatch (hawk/ctx/safe/env/json/cache
# namespaces) which are defined in the hawk runtime (hawk.awk + core/*.awk).
# This file provides no-op stubs so gawk can validate AWK syntax (and run the
# BEGIN block harmlessly) without needing the full runtime.
#
# NOTE: dsl/adt.awk (result_ok/result_ng/option_some/... in the default "awk"
# namespace) and dsl/type.awk (type::accepts/coerce/normalize, used by the
# non-Error type-alias validator constructors emitted for `type X = A | B`,
# wave 27 追補 H4) are loaded separately by libexec/hawk-check and
# libexec/hawk-emit since both are real, pure, dependency-free code -- no
# stub needed for them.

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

@namespace "json"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"

@namespace "cache"
function dispatch(path, a1, a2, a3) { return 0 }
@namespace "awk"
