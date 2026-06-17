function get_cached(key) {
  return option_none_make()
}

function handler(    _ds_tc_1, val) {
  _ds_tc_1 = get_cached("foo")
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  val = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", val)
}
