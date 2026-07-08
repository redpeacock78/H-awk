function find_item(x) {
  return x
}

function handler(    _ds_mc_1, val) {
  _ds_mc_1 = find_item(id)
  if (option_some(_ds_mc_1)) {
    val = option_val(_ds_mc_1)
    return ctx::dispatch("res.json", val)
  } else {
    return ctx::dispatch("res.status", 404)
  }
}
