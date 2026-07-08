function ReadError(msg) { return result_ng("ReadError", msg) }
function ParseError(msg) { return result_ng("ParseError", msg) }

function fetch() {
}

function handler(    _ds_mc_1, x, _ds_mc_2, value, e) {
  _ds_mc_1 = fetch()
  if (result_ok(_ds_mc_1)) {
    x = result_val(_ds_mc_1)
    return ctx::dispatch("res.text", x)
  } else {
    x = result_err(_ds_mc_1)
    x = x
  }
  _ds_mc_2 = x
  if (result_ok(_ds_mc_2)) {
    value = result_val(_ds_mc_2)
    return ctx::dispatch("res.status", value)
  } else if (awk::result_err_type(_ds_mc_2) == "ReadError") {
    e = result_err(_ds_mc_2)
    return ctx::dispatch("res.status", 400)
  }
}
