function handler(    _ds_mc_1, body, e) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else if (result_err_type(_ds_mc_1) == "AuthError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 401)
  } else if (result_err_type(_ds_mc_1) == "NotFoundError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 404)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
