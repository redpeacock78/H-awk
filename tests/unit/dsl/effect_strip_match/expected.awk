function get_item(id) {
  return option_none_make()
}

function handler(    _ds_mc_1, val) {
  _ds_mc_1 = get_item(id)
  if (option_some(_ds_mc_1)) {
    val = option_val(_ds_mc_1)
    return ctx::dispatch("res.text", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
