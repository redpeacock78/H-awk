type Bag = {
  items: Dict<Str, Int>
}

function run() -> Response {
  let bag: Bag = { items: "{}" }
  bag.items = "oops"
}
