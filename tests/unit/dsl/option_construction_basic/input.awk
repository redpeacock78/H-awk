function find_title(id) {
  if (!(id in rows)) {
    return option.none()
  }
  return option.some(rows[id])
}
