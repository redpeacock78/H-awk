function handler() {
  when find_item(id) of
    some:
      return ctx.res.status(200)
    none:
      return ctx.res.status(404)
  end
}
