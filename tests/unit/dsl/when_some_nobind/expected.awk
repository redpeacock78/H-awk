function handler(    _ds_mc_1) {
  _ds_mc_1 = find_item(id)
  if (result_ok(_ds_mc_1)) {
    return ctx::dispatch("res.status", 200)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
