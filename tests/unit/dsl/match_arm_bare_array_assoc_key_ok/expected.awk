function _todo_tr(id, title) {
  return id title
}

function handler(    raw_title, _ds_mc_1, raw, row, err) {
  raw_title = ctx::dispatch("req.form", "title")
  _ds_mc_1 = raw_title
  if (result_ok(_ds_mc_1)) {
    raw = result_val(_ds_mc_1)
    delete row
    row["id"] = "abc"
    row["title"] = raw
    return _todo_tr(row["id"], row["title"])
  } else {
    err = result_err(_ds_mc_1)
    return ""
  }
}
