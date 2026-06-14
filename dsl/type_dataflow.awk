# SPDX-License-Identifier: MIT
# dsl/type_dataflow.awk -- Untrusted<T> and Safe<T> type tracking
#
# _DS_FUNC_CLASS[name] = "transform"|"validator"|"sanitizer"|"sink"

function _ds_is_untrusted(t) { return t ~ /^Untrusted</ }
function _ds_is_safe(t)      { return t ~ /^Safe</ }

function _ds_untrusted_inner(t,    m) {
    if (match(t, /^Untrusted<(.+)>$/, m)) return m[1]
    return t
}

function _ds_safe_inner(t,    m) {
    if (match(t, /^Safe<(.+)>$/, m)) return m[1]
    return t
}

# Given function name and input type, compute output type considering classify.
function _ds_dataflow_ret(fname, input_type,    cls, ret) {
    cls = _DS_FUNC_CLASS[fname]
    ret = _DS_SIG_RET[fname]
    if ((cls == "transform" || cls == "validator") && _ds_is_untrusted(input_type))
        return "Untrusted<" ret ">"
    return ret
}

function _ds_type_kind(t,    expanded) {
    expanded = (t in awk::_DS_TYPE_ALIAS) ? awk::_DS_TYPE_ALIAS[t] : t
    return awk::_DS_TYPE_KIND[expanded]
}

function _ds_is_brand(t) { return _ds_type_kind(t) == "brand" }
