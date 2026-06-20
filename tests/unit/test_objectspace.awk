# SPDX-License-Identifier: MIT
# tests/unit/test_objectspace.awk

function test_objectspace_register_resolve(    r) {
  objectspace::_reset()
  objectspace::register("cache", "proc://cache/global")
  r = objectspace::resolve("cache")
  assert_eq(r, "proc://cache/global", "objectspace: register/resolve")
}

function test_objectspace_resolve_unknown() {
  objectspace::_reset()
  assert_eq(objectspace::resolve("no_such"), "", "objectspace: resolve unknown = empty")
}

function test_objectspace_unregister(    r) {
  objectspace::_reset()
  objectspace::register("svc", "proc://svc/1")
  objectspace::unregister("svc")
  assert_eq(objectspace::resolve("svc"), "", "objectspace: unregister clears name")
}
