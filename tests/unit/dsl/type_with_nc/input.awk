function setup() {
  let port: Int = env::dispatch("get", "PORT") ?? 8080
}
