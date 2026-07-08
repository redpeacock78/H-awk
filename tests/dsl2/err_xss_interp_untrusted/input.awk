function handler(ctx) {
  let raw ?= ctx.req.form("name")
  let html = "<p>#{raw}</p>"
  ctx.res.html(safe.html.raw(html))
}
