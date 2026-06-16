function handler(    _ds_mc_1, err) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    return ctx::dispatch("res.status", 200)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
