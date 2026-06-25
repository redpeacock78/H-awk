function need_int(x) {
  return ctx::dispatch("res.status", x)
}

function need_str(x) {
  return ctx::dispatch("res.text", x)
}

function fetch() {
}

function handler(    _ds_mc_1, x) {
  _ds_mc_1 = fetch()
  if (result_ok(_ds_mc_1)) {
    x = result_val(_ds_mc_1)
    return need_int(x)
  } else {
    x = result_err(_ds_mc_1)
    return need_str(x)
  }
}
