function h() -> Response {
  when ctx.req.form("title") of
    ok raw:
      let escaped = raw |> safe.html.escape()
      return ctx.res.html(escaped)
    ng:
      return ctx.res.status(400)
  end
}
