function fetch_user(id) {
}

function handler(    _ds_mc_1, user) {
  _ds_mc_1 = fetch_user(id)
  if (result_ok(_ds_mc_1)) {
    user = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", user)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
