function handler(ctx) {
  when ctx.req.form("name") of
    ok raw:
      return ctx.res.html(raw)
    ng e:
      return ctx.res.text("error")
  end
}
