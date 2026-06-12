# SPDX-License-Identifier: MIT
# dsl/type.awk -- DSL 型アノテーション用ランタイム変換 + 型レジストリ
#
# type::coerce(val, typename)  -- ランタイム型変換（デシュガー出力から呼ばれる）
# _DS_TYPE_RETURNS[]           -- 既知 DSL 関数の戻り型（デシュガー時静的チェック用）

@namespace "type"

function coerce(val, typename) {
    if (typename == "Int") {
        if (val !~ /^-?[0-9]+$/) {
            print "type error: cannot coerce \"" val "\" to Int" > "/dev/stderr"
            exit 1
        }
        return int(val)
    }

    if (typename == "Float") {
        if (val !~ /^-?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$/) {
            print "type error: cannot coerce \"" val "\" to Float" > "/dev/stderr"
            exit 1
        }
        return val + 0
    }

    if (typename == "Str") {
        return val ""
    }

    if (typename == "Bool") {
        if (val == "true" || val == "1") return 1
        if (val == "false" || val == "0" || val == "") return 0
        print "type error: cannot coerce \"" val "\" to Bool" > "/dev/stderr"
        exit 1
    }

    print "type::coerce: unknown type: " typename > "/dev/stderr"
    exit 1
}

@namespace "awk"

# 既知の DSL 関数の戻り型 (デシュガー時の静的チェックに使用)
# キー: "namespace.method" の dot 記法文字列
BEGIN {
    _DS_TYPE_RETURNS["env.get"]       = "Str"
    _DS_TYPE_RETURNS["ctx.req.form"]  = "Str"
    _DS_TYPE_RETURNS["ctx.req.query"] = "Str"
    _DS_TYPE_RETURNS["ctx.req.param"] = "Str"
    _DS_TYPE_RETURNS["ctx.req.body"]  = "Str"
}
