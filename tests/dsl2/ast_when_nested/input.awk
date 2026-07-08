function todo_list_html() -> Response {
  when cache.get("todos:html") of
    ok r:
      when r of
        some v:
          return ctx.res.html(safe.html.raw(v))
        none:
          # fall through to rebuild
      end
    ng _:
      # fall through to rebuild on cache error
  end
}
