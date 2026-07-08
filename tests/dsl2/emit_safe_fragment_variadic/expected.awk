function run(    _ds_frag_args_1) {
  delete _ds_frag_args_1
  _ds_frag_args_1[1] = "<b>"
  _ds_frag_args_1[2] = "a"
  _ds_frag_args_1[3] = "</b>"
  _ds_frag_args_1[4] = "<i>x</i>"
  return safe::fragment_v(_ds_frag_args_1, 4)
}
