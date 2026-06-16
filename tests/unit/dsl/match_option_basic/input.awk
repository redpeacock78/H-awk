function handler() {
  when find_item(id) of
    some val:
      return ctx.res.json(val)
    none:
      return ctx.res.status(404)
  end
}
