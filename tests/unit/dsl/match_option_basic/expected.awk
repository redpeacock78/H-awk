function handler(    _ds_mc_1, val) {
  _ds_mc_1 = find_item(id)
  if (result_ok(_ds_mc_1)) {
    val = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
