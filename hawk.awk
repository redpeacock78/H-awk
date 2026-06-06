# H-awk core entry. Aggregates core/*.awk via @include in dependency order.
# This file is loaded by gawk before app.awk, plugins, and tests.

@include "core/util.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
