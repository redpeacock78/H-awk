@namespace "app"
function handler(x,    _ds_mc_1, n, err, _ds_mc_2, y) {
  x = lookup()
  _ds_mc_1 = x
  if (result_ok(_ds_mc_1)) {
    n = result_val(_ds_mc_1)
    pass()
  } else {
    err = result_err(_ds_mc_1)
    _ds_mc_2 = inner()
    if (result_ok(_ds_mc_2)) {
      y = result_val(_ds_mc_2)
      pass()
    }
  }
}
