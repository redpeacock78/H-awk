@namespace "app"
function outer() {
  return 1
}

function inner() {
  return 1
}

function handler(x,    _ds_mc_1, _ds_mc_2) {
  x = outer()
  _ds_mc_1 = x
  if (result_ok(_ds_mc_1)) {
    x = result_val(_ds_mc_1)
    _ds_mc_2 = inner()
    if (result_ok(_ds_mc_2)) {
      x = result_val(_ds_mc_2)
      return x
    }
  }
}
