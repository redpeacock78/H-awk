function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng e: AuthError:
      return ctx.res.status(401)
    ng e: NotFoundError:
      return ctx.res.status(404)
    default:
      return ctx.res.status(500)
  end
}
