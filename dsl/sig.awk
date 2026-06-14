# SPDX-License-Identifier: MIT
# dsl/sig.awk -- DSL function signature registry
#
# _DS_SIG_RET[path]        : return type string
# _DS_SIG_ARITY[path]      : argument count (exact)
# _DS_SIG_ARG[path, index] : argument type, 1-indexed

BEGIN {
    # Type aliases
    _DS_TYPE_ALIAS["Port"]        = "Int|NumericStr|Str"
    _DS_TYPE_ALIAS["HandlerName"] = "Str"

    # Safe<T> backward-compat aliases → brand types
    _DS_TYPE_ALIAS["Safe<HtmlStr>"] = "HtmlEscapedStr"
    _DS_TYPE_ALIAS["Safe<Str>"]     = "Str"

    # Brand type kind table
    _DS_TYPE_KIND["HtmlEscapedStr"]      = "brand"
    _DS_TYPE_KIND["HtmlFragment"]        = "brand"
    _DS_TYPE_KIND["HtmlAttrEscapedStr"]  = "brand"

    # env.*
    _DS_SIG_RET["env.get"]        = "Str"
    _DS_SIG_ARITY["env.get"]      = 1
    _DS_SIG_ARG["env.get", 1]     = "Str"

    _DS_SIG_RET["env.set"]        = "Void"
    _DS_SIG_ARITY["env.set"]      = 2
    _DS_SIG_ARG["env.set", 1]     = "Str"
    _DS_SIG_ARG["env.set", 2]     = "Str"

    _DS_SIG_RET["env.del"]        = "Void"
    _DS_SIG_ARITY["env.del"]      = 1
    _DS_SIG_ARG["env.del", 1]     = "Str"

    _DS_SIG_RET["env.has"]        = "Bool"
    _DS_SIG_ARITY["env.has"]      = 1
    _DS_SIG_ARG["env.has", 1]     = "Str"

    # ctx.req.*
    _DS_SIG_RET["ctx.req.form"]      = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_ARITY["ctx.req.form"]    = 1
    _DS_SIG_ARG["ctx.req.form", 1]   = "Str"

    _DS_SIG_RET["ctx.req.query"]     = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_ARITY["ctx.req.query"]   = 1
    _DS_SIG_ARG["ctx.req.query", 1]  = "Str"

    _DS_SIG_RET["ctx.req.param"]     = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_ARITY["ctx.req.param"]   = 1
    _DS_SIG_ARG["ctx.req.param", 1]  = "Str"

    _DS_SIG_RET["ctx.req.header"]    = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_ARITY["ctx.req.header"]  = 1
    _DS_SIG_ARG["ctx.req.header", 1] = "Str"

    _DS_SIG_RET["ctx.req.body"]      = "Result<Untrusted<Str>, ParseError>"
    _DS_SIG_ARITY["ctx.req.body"]    = 0

    _DS_SIG_RET["ctx.req.json"]      = "Result<Untrusted<Map>, ParseError>"
    _DS_SIG_ARITY["ctx.req.json"]    = 0

    # ctx.res.*
    _DS_SIG_RET["ctx.res.json"]      = "Response"
    _DS_SIG_ARITY["ctx.res.json"]    = 1
    _DS_SIG_ARG["ctx.res.json", 1]   = "Safe<JsonStr>"

    _DS_SIG_RET["ctx.res.text"]      = "Response"
    _DS_SIG_ARITY["ctx.res.text"]    = 1
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str|Untrusted<Str>"

    _DS_SIG_RET["ctx.res.html"]      = "Response"
    _DS_SIG_ARITY["ctx.res.html"]    = 1
    _DS_SIG_ARG["ctx.res.html", 1]   = "HtmlEscapedStr|HtmlFragment"

    # escape_html: built-in trusted sanitizer
    _DS_SIG_RET["escape_html"]       = "HtmlEscapedStr"
    _DS_SIG_ARITY["escape_html"]     = 1
    _DS_SIG_ARG["escape_html", 1]    = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["escape_html"]    = "sanitizer"
    _DS_SIG_TRUSTED["escape_html"]   = 1

    # html_raw: assert-trust escape hatch for pre-built HTML strings
    _DS_SIG_RET["html_raw"]          = "HtmlEscapedStr"
    _DS_SIG_ARITY["html_raw"]        = 1
    _DS_SIG_ARG["html_raw", 1]       = "Str"
    _DS_SIG_TRUSTED["html_raw"]      = 1

    _DS_SIG_RET["ctx.res.render"]    = "Response"
    _DS_SIG_ARITY["ctx.res.render"]  = 1
    _DS_SIG_ARG["ctx.res.render", 1] = "Str"

    _DS_SIG_RET["ctx.res.status"]    = "Response"
    _DS_SIG_ARITY["ctx.res.status"]  = 1
    _DS_SIG_ARG["ctx.res.status", 1] = "Int"

    _DS_SIG_RET["ctx.res.header"]    = "Response"
    _DS_SIG_ARITY["ctx.res.header"]  = 2
    _DS_SIG_ARG["ctx.res.header", 1] = "Str"
    _DS_SIG_ARG["ctx.res.header", 2] = "Str"

    _DS_SIG_RET["ctx.res.redirect"]   = "Response"
    _DS_SIG_ARITY["ctx.res.redirect"] = 1
    _DS_SIG_ARG["ctx.res.redirect", 1] = "Str"

    # hawk.app.*  (route registration: always arity=2, Str path + HandlerName)
    _DS_SIG_RET["hawk.app.get"]       = "Void"
    _DS_SIG_ARITY["hawk.app.get"]     = 2
    _DS_SIG_ARG["hawk.app.get", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.get", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.post"]      = "Void"
    _DS_SIG_ARITY["hawk.app.post"]    = 2
    _DS_SIG_ARG["hawk.app.post", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.post", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.put"]       = "Void"
    _DS_SIG_ARITY["hawk.app.put"]     = 2
    _DS_SIG_ARG["hawk.app.put", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.put", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.del"]       = "Void"
    _DS_SIG_ARITY["hawk.app.del"]     = 2
    _DS_SIG_ARG["hawk.app.del", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.del", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.patch"]     = "Void"
    _DS_SIG_ARITY["hawk.app.patch"]   = 2
    _DS_SIG_ARG["hawk.app.patch", 1]  = "Str"
    _DS_SIG_ARG["hawk.app.patch", 2]  = "HandlerName"

    _DS_SIG_RET["hawk.app.head"]      = "Void"
    _DS_SIG_ARITY["hawk.app.head"]    = 2
    _DS_SIG_ARG["hawk.app.head", 1]   = "Str"
    _DS_SIG_ARG["hawk.app.head", 2]   = "HandlerName"

    _DS_SIG_RET["hawk.app.on"]        = "Void"
    _DS_SIG_ARITY["hawk.app.on"]      = 2
    _DS_SIG_ARG["hawk.app.on", 1]     = "Str"
    _DS_SIG_ARG["hawk.app.on", 2]     = "HandlerName"

    _DS_SIG_RET["hawk.app.all"]       = "Void"
    _DS_SIG_ARITY["hawk.app.all"]     = 2
    _DS_SIG_ARG["hawk.app.all", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.all", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.listen"]    = "Void"
    _DS_SIG_ARITY["hawk.app.listen"]  = 1
    _DS_SIG_ARG["hawk.app.listen", 1] = "Port"
}
