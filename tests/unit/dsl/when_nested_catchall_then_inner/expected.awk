@namespace "app"
function lookup() {
  return 1
}

function pass() {
  return 1
}

function inner() {
  return 1
}

function handler(x,    _ds_mc_1, n, _ds_mc_2, y) {
  x = lookup()
  _ds_mc_1 = x
  if (result_ok(_ds_mc_1)) {
    n = result_val(_ds_mc_1)
    pass()
  } else {
    _ds_mc_2 = inner()
    if (result_ok(_ds_mc_2)) {
      y = result_val(_ds_mc_2)
      pass()
    }
  }
}
