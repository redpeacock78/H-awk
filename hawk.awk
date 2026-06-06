# H-awk core entry. Aggregates core/*.awk via @include in dependency order.
# This file is loaded by gawk before app.awk, plugins, and tests.

@include "core/util.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/router.awk"
@include "core/plugin.awk"
@include "core/http.awk"
