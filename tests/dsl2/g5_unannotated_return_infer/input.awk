function fetch_user() {
  return ctx.req.json()
}

function handler() -> Response {
  when fetch_user() of
    ok u:
      return ctx.res.text("ok")
  end
}
