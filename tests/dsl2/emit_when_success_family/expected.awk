function MyErr(msg) { return result_ng("MyErr", msg) }

function f(x) {
  return result::dispatch("ok", x)
}

function g(    _ds_mc_1, v, e) {
  _ds_mc_1 = f(1)
  if (result_ok(_ds_mc_1)) {
    v = result_val(_ds_mc_1)
    return ctx::dispatch("res.text", "ok")
  } else {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.text", "err")
  }
}
