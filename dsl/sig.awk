# SPDX-License-Identifier: MIT
# dsl/sig.awk -- DSL function signature registry
#
# _DS_SIG_RET[path]        : return type string
# _DS_SIG_ARITY[path]     : minimum argument count (-1 = variadic)
# _DS_SIG_ARITY_MAX[path] : maximum argument count for optional args
# _DS_SIG_ARG[path, index]: argument type, 1-indexed

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

    # HtmlPart alias: union of all HTML-related brand types
    _DS_TYPE_ALIAS["HtmlPart"] = "HtmlEscapedStr|HtmlFragment|HtmlAttrEscapedStr"

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
    _DS_SIG_ARG["ctx.res.json", 1]   = "Any"

    _DS_SIG_RET["ctx.res.json_raw"]      = "Response"
    _DS_SIG_ARITY["ctx.res.json_raw"]    = 1
    _DS_SIG_ARG["ctx.res.json_raw", 1]   = "Str"

    _DS_SIG_RET["ctx.res.text"]      = "Response"
    _DS_SIG_ARITY["ctx.res.text"]    = 1
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str|Untrusted<Str>"

    _DS_SIG_RET["ctx.res.html"]      = "Response"
    _DS_SIG_ARITY["ctx.res.html"]    = 1
    _DS_SIG_ARG["ctx.res.html", 1]   = "HtmlEscapedStr|HtmlFragment"

    # safe.html.escape: sanitizer — Str|Untrusted<Str> → HtmlEscapedStr
    _DS_SIG_RET["safe.html.escape"]         = "HtmlEscapedStr"
    _DS_SIG_ARITY["safe.html.escape"]       = 1
    _DS_SIG_ARG["safe.html.escape", 1]      = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["safe.html.escape"]      = "sanitizer"
    _DS_SIG_TRUSTED["safe.html.escape"]     = 1

    # safe.attr.escape: sanitizer — Str|Untrusted<Str> → HtmlAttrEscapedStr
    _DS_SIG_RET["safe.attr.escape"]         = "HtmlAttrEscapedStr"
    _DS_SIG_ARITY["safe.attr.escape"]       = 1
    _DS_SIG_ARG["safe.attr.escape", 1]      = "Str|Untrusted<Str>"
    _DS_FUNC_CLASS["safe.attr.escape"]      = "sanitizer"
    _DS_SIG_TRUSTED["safe.attr.escape"]     = 1

    # safe.str.trust: explicit trust assertion — Untrusted<Str> → Str (no transformation)
    _DS_SIG_RET["safe.str.trust"]           = "Str"
    _DS_SIG_ARITY["safe.str.trust"]         = 1
    _DS_SIG_ARG["safe.str.trust", 1]        = "Untrusted<Str>"
    _DS_FUNC_CLASS["safe.str.trust"]        = "trusted"
    _DS_SIG_TRUSTED["safe.str.trust"]       = 1

    # safe.html.raw: trust assertion — Str → HtmlFragment (does not escape)
    _DS_SIG_RET["safe.html.raw"]            = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.raw"]          = 1
    _DS_SIG_ARG["safe.html.raw", 1]         = "Str"
    _DS_FUNC_CLASS["safe.html.raw"]         = "trusted"
    _DS_SIG_TRUSTED["safe.html.raw"]        = 1

    # safe.html.fragment: builder — variadic HtmlPart args → HtmlFragment
    _DS_SIG_RET["safe.html.fragment"]       = "HtmlFragment"
    _DS_SIG_ARITY["safe.html.fragment"]     = -1
    _DS_SIG_ARG["safe.html.fragment", 1]    = "HtmlPart"
    _DS_FUNC_CLASS["safe.html.fragment"]    = "builder"
    _DS_SIG_TRUSTED["safe.html.fragment"]   = 1

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

    _DS_SIG_RET["ctx.res.redirect"]    = "Response"
    _DS_SIG_ARITY["ctx.res.redirect"]  = 1
    _DS_SIG_ARITY_MAX["ctx.res.redirect"] = 2
    _DS_SIG_ARG["ctx.res.redirect", 1] = "Str"
    _DS_SIG_ARG["ctx.res.redirect", 2] = "Int"

    # hawk.app.*  (route registration)
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
    _DS_SIG_ARITY["hawk.app.on"]      = 3
    _DS_SIG_ARG["hawk.app.on", 1]     = "Str"
    _DS_SIG_ARG["hawk.app.on", 2]     = "Str"
    _DS_SIG_ARG["hawk.app.on", 3]     = "HandlerName"

    _DS_SIG_RET["hawk.app.all"]       = "Void"
    _DS_SIG_ARITY["hawk.app.all"]     = 2
    _DS_SIG_ARG["hawk.app.all", 1]    = "Str"
    _DS_SIG_ARG["hawk.app.all", 2]    = "HandlerName"

    _DS_SIG_RET["hawk.app.listen"]    = "Void"
    _DS_SIG_ARITY["hawk.app.listen"]  = 1
    _DS_SIG_ARG["hawk.app.listen", 1] = "Port"

    # app runtime helpers (TSV storage + JSON)
    _DS_SIG_RET["read_tsv"]        = "Int"
    _DS_SIG_ARITY["read_tsv"]      = 2
    _DS_SIG_ARG["read_tsv", 1]     = "Str"
    _DS_SIG_ARG["read_tsv", 2]     = "Array"

    _DS_SIG_RET["delete_tsv"]      = "Int"
    _DS_SIG_ARITY["delete_tsv"]    = 3
    _DS_SIG_ARG["delete_tsv", 1]   = "Str"
    _DS_SIG_ARG["delete_tsv", 2]   = "Str"
    _DS_SIG_ARG["delete_tsv", 3]   = "Str|Untrusted<Str>"

    _DS_SIG_RET["append_tsv"]      = "Void"
    _DS_SIG_ARITY["append_tsv"]    = 2
    _DS_SIG_ARG["append_tsv", 1]   = "Str"
    _DS_SIG_ARG["append_tsv", 2]   = "Array"

    _DS_SIG_RET["json_encode"]     = "Str"
    _DS_SIG_ARITY["json_encode"]   = 1
    _DS_SIG_ARG["json_encode", 1]  = "Array"

    # option constructors
    _DS_SIG_RET["option.some"]    = "Option<Any>"
    _DS_SIG_ARITY["option.some"]  = 1
    _DS_SIG_ARG["option.some", 1] = "Any"

    _DS_SIG_RET["option.none"]    = "Option<Any>"
    _DS_SIG_ARITY["option.none"]  = 0

    # cache.*
    _DS_SIG_RET["cache.get"]         = "Str"
    _DS_SIG_ARITY["cache.get"]       = 1
    _DS_SIG_ARG["cache.get", 1]      = "Str"

    _DS_SIG_RET["cache.set"]         = "Void"
    _DS_SIG_ARITY["cache.set"]       = 3
    _DS_SIG_ARG["cache.set", 1]      = "Str"
    _DS_SIG_ARG["cache.set", 2]      = "Any"
    _DS_SIG_ARG["cache.set", 3]      = "Int"

    _DS_SIG_RET["cache.del"]         = "Void"
    _DS_SIG_ARITY["cache.del"]       = 1
    _DS_SIG_ARG["cache.del", 1]      = "Str"

    _DS_SIG_RET["cache.has"]         = "Bool"
    _DS_SIG_ARITY["cache.has"]       = 1
    _DS_SIG_ARG["cache.has", 1]      = "Str"

    _DS_SIG_RET["cache.remember"]    = "Str"
    _DS_SIG_ARITY["cache.remember"]  = 3
    _DS_SIG_ARG["cache.remember", 1] = "Str"
    _DS_SIG_ARG["cache.remember", 2] = "Int"
    _DS_SIG_ARG["cache.remember", 3] = "HandlerName"

    _DS_SIG_RET["cache.stats"]       = "Str"
    _DS_SIG_ARITY["cache.stats"]     = 0

    _DS_SIG_RET["cache.backend"]     = "Str"
    _DS_SIG_ARITY["cache.backend"]   = 0

    _DS_SIG_RET["cache.found"]       = "Bool"
    _DS_SIG_ARITY["cache.found"]     = 0
}
