function fallback() {
  return "fb"
}
function h(v) {
  return v
}
function f(    _ds_p_1, _ds_tc_1) {
  _ds_tc_1 = env::dispatch("get", "X")
  if (_ds_tc_1 == "") {
    _ds_p_1 = h(fallback())
    _ds_tc_1 = _ds_p_1
  }
  return _ds_tc_1
}
