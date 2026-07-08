function fetch_user(id) {
}

function handler(    _ds_mc_1, user, e) {
  _ds_mc_1 = fetch_user(id)
  if (result_ok(_ds_mc_1)) {
    user = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", user)
  } else if (awk::result_err_type(_ds_mc_1) == "AuthError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 401)
  } else if (awk::result_err_type(_ds_mc_1) == "NotFoundError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 404)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
