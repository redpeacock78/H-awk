# SPDX-License-Identifier: MIT
# core/proc.awk -- proc facade
@namespace "proc"

function self(    id) {
  id = ENVIRON["HAWK_PROC_ID"]
  if (id != "") return id
  return "pid:" PROCINFO["pid"]
}

function register(name, pid) {
  return objectspace::register(name, pid)
}

function whereis(name) {
  return objectspace::resolve(name)
}

function cast(name_or_pid, message_str,    oid) {
  oid = objectspace::resolve(name_or_pid)
  if (oid == "") oid = name_or_pid
  mailbox::send(oid, message_str)
}

function call(name_or_pid, message_str, timeout_ms,    oid, out) {
  oid = objectspace::resolve(name_or_pid)
  if (oid == "") oid = name_or_pid
  if (!message::decode(message_str, out)) return ""
  return mailbox::wait_reply(out["ref"], timeout_ms)
}

@namespace "awk"
