function todo_add() -> Response {
  let raw_title = ctx.req.form("title")
  when raw_title of
    ok raw:
      if (raw == "") {
        let raw_q ?= ctx.req.query("title")
        raw = raw_q
      }
      return ctx.res.text(raw)
    ng _:
      return ctx.res.status(500)
  end
}
