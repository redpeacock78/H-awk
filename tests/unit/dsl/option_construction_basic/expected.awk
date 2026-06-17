function find_title(id) {
  if (!(id in rows)) {
    return option_none_make()
  }
  return option_some_make(rows[id])
}
