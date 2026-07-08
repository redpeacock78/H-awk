function id(x) {
  return x
}
function inc() {
  return 1
}
function run(    _ds_p_1) {
  _ds_p_1 = id(inc())
  return ctx::dispatch("res.json", _ds_p_1)
}
