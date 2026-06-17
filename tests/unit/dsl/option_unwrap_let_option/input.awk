function find_title(id: Str) -> Option<Str> {
  return option.none()
}

function handler() {
  let title ?= find_title(id)
  return ctx.res.text(title)
}
