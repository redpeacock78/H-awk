function AuthError(msg) { return result_ng("AuthError", msg) }

function f(x) {
  if (x < 0) {
  return AuthError("negative")
  }
  return result_ok_make(x)
}

function handler(    _ds_mc_1, v, e) {
  _ds_mc_1 = f(1)
  if (result_ok(_ds_mc_1)) {
    v = result_val(_ds_mc_1)
    return ctx::dispatch("res.text", "ok")
  } else if (awk::result_err_type(_ds_mc_1) == "AuthError") {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 401)
  }
}
