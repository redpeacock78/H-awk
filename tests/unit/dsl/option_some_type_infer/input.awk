function find_title(id: Str) -> Option<Str> {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}
