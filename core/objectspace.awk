# SPDX-License-Identifier: MIT
# core/objectspace.awk -- logical name -> proc ID resolution
@namespace "objectspace"

function register(name, object_id) {
  _registry[name] = object_id
  return 1
}

function resolve(name) {
  if (name in _registry) return _registry[name]
  return ""
}

function unregister(name) {
  delete _registry[name]
}

function cast(name, selector, args_str,    oid, enc) {
  oid = resolve(name)
  if (oid == "") return
  enc = message::make_cast(oid, ENVIRON["HAWK_PROC_ID"], selector, args_str)
  mailbox::send(oid, enc)
}

function call(name, selector, args_str, timeout_ms,    oid, reply_to, ref_val, enc, out, line) {
  oid = resolve(name)
  if (oid == "") return ""
  ref_val  = message::ref()
  reply_to = mailbox::_reply_path(ref_val)
  enc      = message::make_call(oid, ENVIRON["HAWK_PROC_ID"], selector, args_str, reply_to, timeout_ms)
  mailbox::send(oid, enc)
  line = mailbox::call(oid, enc, timeout_ms)
  if (line == "") return ""
  delete out
  if (!message::decode(line, out)) return ""
  return out["args"]
}

function _reset(    k) {
  for (k in _registry) delete _registry[k]
}

@namespace "awk"
