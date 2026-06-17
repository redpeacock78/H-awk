function find_title(id) {
  return option_none_make()
}

function handler(    _ds_tc_1, title) {
  _ds_tc_1 = find_title(id)
  if (!option_some(_ds_tc_1)) {
    return ctx::dispatch("res.status", 404)
  }
  title = option_val(_ds_tc_1)
  return ctx::dispatch("res.text", title)
}
