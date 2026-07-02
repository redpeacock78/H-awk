function handler(    _ds_mc_1, body, _ds_mct_1) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    result_val_into_map(_ds_mc_1, body, _ds_mct_1)
    return json(res, body, _ds_mct_1)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
