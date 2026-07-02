function handler(    _ds_mc_1, xs, err, _ds_mct_1) {
  _ds_mc_1 = ctx::dispatch("req.json_t", "Array")
  if (result_ok(_ds_mc_1)) {
    result_val_into_map(_ds_mc_1, xs, _ds_mct_1)
    xs["__json_type"] = "array"
    return json(res, xs, _ds_mct_1)
  } else {
    err = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
