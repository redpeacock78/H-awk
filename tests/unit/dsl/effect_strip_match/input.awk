function get_item(id: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  when get_item(id) of
    some val:
      return ctx.res.text(val)
    none:
      return ctx.res.status(404)
  end
}
