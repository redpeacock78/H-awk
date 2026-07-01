function handler(    _ds_mc_1, body, err, body_types) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    result_val_into_map(_ds_mc_1, body, body_types)
    return ctx::dispatch("res.json", body)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
