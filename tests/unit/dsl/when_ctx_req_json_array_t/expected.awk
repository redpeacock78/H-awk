function handler(    _ds_mc_1, xs, err) {
  _ds_mc_1 = ctx::dispatch("req.json_t", "Array")
  if (result_ok(_ds_mc_1)) {
    xs = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", xs)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
