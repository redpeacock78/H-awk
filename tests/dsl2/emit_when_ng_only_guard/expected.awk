function MyErr(msg) { return result_ng("MyErr", msg) }

function f(x) {
  return result_ok_make(x)
}

function g(    _ds_mc_1, e) {
  _ds_mc_1 = f(1)
  if (result_ok(_ds_mc_1)) {
  } else {
    e = result_err(_ds_mc_1)
    return ctx::dispatch("res.text", "err")
  }
  return ctx::dispatch("res.text", "after")
}
