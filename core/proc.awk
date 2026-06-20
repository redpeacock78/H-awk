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

function call(name_or_pid, message_str, timeout_ms,    oid, out, ref_val, reply_fifo) {
  oid = objectspace::resolve(name_or_pid)
  if (oid == "") oid = name_or_pid
  delete out
  if (!message::decode(message_str, out)) return ""
  ref_val    = out["ref"]
  reply_fifo = mailbox::_reply_path(ref_val)
  system("mkfifo " mailbox::shell_quote(reply_fifo))
  if (!mailbox::send(oid, message_str)) {
    system("rm -f " mailbox::shell_quote(reply_fifo))
    return ""
  }
  return mailbox::wait_reply(ref_val, timeout_ms)
}

@namespace "awk"
