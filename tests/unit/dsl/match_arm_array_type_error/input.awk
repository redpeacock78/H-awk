function _todo_tr(id: Str, title: Str) -> Str {
  return id title
}

function handler() -> Str {
  let raw_title = ctx.req.form("title")
  match raw_title of
    ok raw:
      let row = []
      row["id"] = "abc"
      row["title"] = raw
      return _todo_tr(row["id"], row["title"])
    ng err:
      return ""
  end
}
