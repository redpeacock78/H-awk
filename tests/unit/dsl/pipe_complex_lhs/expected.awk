function get_user(x) {
  return x
}

function validate_user(x) {
  return x
}

function handler(    _ds_p_1) {
  _ds_p_1 = validate_user(get_user(ctx::dispatch("req.param", "id")))
  return _ds_p_1
}
