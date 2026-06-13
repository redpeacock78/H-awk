# SPDX-License-Identifier: MIT
# dsl/sig.awk -- DSL function signature registry
#
# _DS_SIG_RET[path]        : return type string
# _DS_SIG_ARITY[path]      : argument count (exact)
# _DS_SIG_ARG[path, index] : argument type, 1-indexed

BEGIN {
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
    _DS_SIG_RET["ctx.req.form"]      = "Str"
    _DS_SIG_ARITY["ctx.req.form"]    = 1
    _DS_SIG_ARG["ctx.req.form", 1]   = "Str"

    _DS_SIG_RET["ctx.req.query"]     = "Str"
    _DS_SIG_ARITY["ctx.req.query"]   = 1
    _DS_SIG_ARG["ctx.req.query", 1]  = "Str"

    _DS_SIG_RET["ctx.req.param"]     = "Str"
    _DS_SIG_ARITY["ctx.req.param"]   = 1
    _DS_SIG_ARG["ctx.req.param", 1]  = "Str"

    _DS_SIG_RET["ctx.req.header"]    = "Str"
    _DS_SIG_ARITY["ctx.req.header"]  = 1
    _DS_SIG_ARG["ctx.req.header", 1] = "Str"

    _DS_SIG_RET["ctx.req.body"]      = "Str"
    _DS_SIG_ARITY["ctx.req.body"]    = 0

    _DS_SIG_RET["ctx.req.json"]      = "Result<Map, Error>"
    _DS_SIG_ARITY["ctx.req.json"]    = 0

    # ctx.res.*
    _DS_SIG_RET["ctx.res.json"]      = "Response"
    _DS_SIG_ARITY["ctx.res.json"]    = 1
    _DS_SIG_ARG["ctx.res.json", 1]   = "Str"

    _DS_SIG_RET["ctx.res.text"]      = "Response"
    _DS_SIG_ARITY["ctx.res.text"]    = 1
    _DS_SIG_ARG["ctx.res.text", 1]   = "Str"

    _DS_SIG_RET["ctx.res.html"]      = "Response"
    _DS_SIG_ARITY["ctx.res.html"]    = 1
    _DS_SIG_ARG["ctx.res.html", 1]   = "Str"

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
    _DS_SIG_ARG["hawk.app.listen", 1] = "Int"
}
