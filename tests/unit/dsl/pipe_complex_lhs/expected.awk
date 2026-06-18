function handler(    __pipe_tmp_1, _ds_p_1) {
  __pipe_tmp_1 = get_user(ctx::dispatch("req.param", "id"))
  _ds_p_1 = validate_user(__pipe_tmp_1)
  return _ds_p_1
}
