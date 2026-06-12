# SPDX-License-Identifier: MIT
# core/http.awk -- /inet/tcp listener + request ループ
#
# bin/hawk が gawk -f hawk.awk -f <plugins...> -f app.awk として起動する。
# app.awk の BEGIN で GET / POST 等のルート登録が走った後、この core の END で
# サーバーループを開始する。
#
# シャットダウン:
#   bin/hawk が SIGTERM 受信 → gawk へ中継。
#   gawk は次の read で EOF / EINTR を見て HAWK_SHUTDOWN=1 を立て、ループを抜ける。

END {
  if (!_HAWK_LISTEN_CALLED && !env::has("HAWK_NO_SERVE")) {
    _hawk_serve()
  }
}

function listen(port) {
  if (port > 0) HAWK_PORT = port
  _hawk_serve()
  _HAWK_LISTEN_CALLED = 1
}

function _hawk_serve(    libs_list, lib) {
  if (!HAWK_PORT)               HAWK_PORT               = env::get("PORT")                   ? env::get("PORT")                   + 0 : 8080
  if (!HAWK_MAX_HEADER_SIZE)    HAWK_MAX_HEADER_SIZE    = env::get("HAWK_MAX_HEADER_SIZE")   ? env::get("HAWK_MAX_HEADER_SIZE")   + 0 : 8192
  if (!HAWK_MAX_BODY_SIZE)      HAWK_MAX_BODY_SIZE      = env::get("HAWK_MAX_BODY_SIZE")     ? env::get("HAWK_MAX_BODY_SIZE")     + 0 : 1048576
  if (!HAWK_REQUEST_TIMEOUT)    HAWK_REQUEST_TIMEOUT    = env::get("HAWK_REQUEST_TIMEOUT")   ? env::get("HAWK_REQUEST_TIMEOUT")   + 0 : 30
  if (!HAWK_KEEPALIVE_TIMEOUT)  HAWK_KEEPALIVE_TIMEOUT  = env::get("HAWK_KEEPALIVE_TIMEOUT") ? env::get("HAWK_KEEPALIVE_TIMEOUT") + 0 : 75
  HAWK_DEV = (env::get("DEV") == "1")

  plugin_discover()
  if (PLUGIN_REGISTER_ERROR) {
    log_error("plugin registration failed, exiting.")
    exit 1
  }
  call_hooks("init")

  libs_list = ""
  for (lib in LIBS_LOADED) {
    libs_list = libs_list (libs_list == "" ? "" : ", ") lib
  }
  log_info(sprintf("H-awk listening on http://0.0.0.0:%d%s", \
    HAWK_PORT, \
    libs_list == "" ? "" : " [libs: " libs_list "]"))

  HAWK_SHUTDOWN = 0
  http_serve()

  log_info("shutting down")
  call_hooks("shutdown")
}

function http_serve() {
  if (LIBS_LOADED["net"]) {
    _http_serve_zig()
  } else {
    _http_serve_inet()
  }
}

function _http_serve_inet(    sock, line, headers_raw, body, content_length, raw, hdr_size, req, res, dispatch_ok, start_ms, ok) {
  sock = "/inet/tcp/" HAWK_PORT "/0/0"
  PROCINFO[sock, "READ_TIMEOUT"] = HAWK_REQUEST_TIMEOUT * 1000

  while (!HAWK_SHUTDOWN) {
    headers_raw = ""
    hdr_size = 0
    while (1) {
      ok = (sock |& getline line)
      if (ok <= 0) break
      sub(/\r$/, "", line)
      if (line == "") break
      headers_raw = headers_raw line "\r\n"
      hdr_size += length(line) + 2
      if (hdr_size > HAWK_MAX_HEADER_SIZE) {
        http_send_simple(sock, 431, "Request Header Fields Too Large")
        close(sock)
        headers_raw = ""
        break
      }
    }

    if (headers_raw == "") {
      close(sock)
      continue
    }

    start_ms = now_ms()
    body = ""
    content_length = http_header_get(headers_raw, "Content-Length") + 0
    if (content_length > HAWK_MAX_BODY_SIZE) {
      http_send_simple(sock, 413, "Payload Too Large")
      close(sock)
      continue
    }
    if (content_length > 0) {
      body = http_read_body(sock, content_length)
    }

    raw = headers_raw "\r\n" body
    delete req
    delete res
    delete _ARR_COUNT
    res["status"] = 200
    if (!request_parse(raw, req)) {
      http_send_simple(sock, 400, "Bad Request")
      close(sock)
      continue
    }

    if (call_hooks("pre_request", req, res) == 1) {
      http_send(sock, res, req, start_ms)
      close(sock)
      continue
    }

    dispatch_ok = router_dispatch(req, res)
    if (dispatch_ok == 0) {
      if (!serve_static(req, res)) {
        status(res, 404)
        text(res, "Not Found")
      }
    }

    call_hooks("post_request", req, res)
    http_send(sock, res, req, start_ms)
    close(sock)
  }

  close(sock)
}

function _http_serve_zig(    poll_result, req, res, conn_id, dispatch_ok, start_ms, parts, n) {
  if (!hawk_net_listen(HAWK_PORT)) {
    log_warn(sprintf("libs/net: failed to bind port %d, falling back to /inet/tcp/", HAWK_PORT))
    _http_serve_inet()
    return
  }

  while (!HAWK_SHUTDOWN) {
    poll_result = hawk_net_poll()
    if (poll_result == "") {
      log_warn("libs/net: event loop stopped unexpectedly, falling back to /inet/tcp/")
      _http_serve_inet()
      return
    }

    start_ms = now_ms()
    delete req
    delete res
    delete _ARR_COUNT
    res["status"] = 200

    if (!parse_request_zig(poll_result, req)) {
      n = split(poll_result, parts, "\x1e")
      conn_id = (n >= 1) ? parts[1] : "0"
      _zig_http_send_simple(conn_id, 400, "Bad Request")
      continue
    }

    conn_id = req["_conn_id"]

    if (HAWK_MAX_HEADER_SIZE > 0 && req["_hdr_len"] + 0 > HAWK_MAX_HEADER_SIZE) {
      _zig_http_send_simple(conn_id, 431, "Request Header Fields Too Large")
      continue
    }
    if (HAWK_MAX_BODY_SIZE > 0 && length(req["body"]) > HAWK_MAX_BODY_SIZE) {
      _zig_http_send_simple(conn_id, 413, "Payload Too Large")
      continue
    }

    if (call_hooks("pre_request", req, res) == 1) {
      _zig_http_send(conn_id, res, req, start_ms)
      continue
    }

    dispatch_ok = router_dispatch(req, res)
    if (dispatch_ok == 0) {
      if (!serve_static(req, res)) {
        status(res, 404)
        text(res, "Not Found")
      }
    }

    call_hooks("post_request", req, res)
    _zig_http_send(conn_id, res, req, start_ms)
  }
}

function _zig_http_send(conn_id, res, req, start_ms,    wire, split_pos, head_part, body_part, first_crlf, status_line, headers, content, dur, ts) {
  if (res["sent"]) return

  # Set Connection header based on request keep-alive preference
  if (!("header:connection" in res)) {
    if (req["keep_alive"] == "1") {
      res["header:connection"] = "keep-alive"
      if (!("header:keep-alive" in res)) {
        res["header:keep-alive"] = "timeout=" HAWK_KEEPALIVE_TIMEOUT
      }
    } else {
      res["header:connection"] = "close"
    }
  }

  if (res["_binary_path"] != "" && LIBS_LOADED["binary"]) {
    content = hawk_bin_read(res["_binary_path"])
    res["body"] = ""
    res["header:content-length"] = hawk_bin_length(content)
    wire = response_wire(res)
    split_pos = index(wire, "\r\n\r\n")
    head_part = substr(wire, 1, split_pos - 1)
    first_crlf = index(head_part, "\r\n")
    status_line = substr(head_part, 1, first_crlf - 1)
    headers = substr(head_part, first_crlf + 2) "\r\n"
    hawk_net_respond(conn_id, status_line, headers, content)
  } else {
    wire = response_wire(res)
    split_pos = index(wire, "\r\n\r\n")
    head_part = substr(wire, 1, split_pos - 1)
    body_part = substr(wire, split_pos + 4)
    first_crlf = index(head_part, "\r\n")
    status_line = substr(head_part, 1, first_crlf - 1)
    headers = substr(head_part, first_crlf + 2) "\r\n"
    hawk_net_respond(conn_id, status_line, headers, body_part)
  }
  res["sent"] = 1

  dur = now_ms() - start_ms
  ts  = strftime("%Y-%m-%dT%H:%M:%S%z")
  printf "%s\tINFO\t%s\t%s\t%d\t%d\n", ts, req["method"], req["path"], res["status"], dur
  fflush()
}

function _zig_http_send_simple(conn_id, code, body) {
  hawk_net_respond(conn_id,
    "HTTP/1.1 " code " " response_status_text(code),
    "Content-Type: text/plain; charset=utf-8\r\nContent-Length: " length(body) "\r\n",
    body)
}

function http_read_body(sock, n,    line, ok, prev_rs) {
  if (n <= 0) return ""
  # Use RS = ".{n}" so gawk reads exactly n bytes as the record separator.
  # gawk's RT variable then holds the matched bytes (the body content).
  # This avoids blocking on getline when the body has no trailing newline
  # (e.g. application/x-www-form-urlencoded sent by curl -d).
  prev_rs = RS
  RS = sprintf(".{%d}", n)
  ok = (sock |& getline line)
  line = RT   # RT holds the text that matched RS
  RS = prev_rs
  return substr(line, 1, n)
}

function http_header_get(headers_raw, name,    lines, n, i, k, lname) {
  lname = to_lower(name)
  n = split(headers_raw, lines, "\r\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] == "") continue
    k = index(lines[i], ":")
    if (k == 0) continue
    if (to_lower(trim(substr(lines[i], 1, k - 1))) == lname) {
      return trim(substr(lines[i], k + 1))
    }
  }
  return ""
}

function http_send(sock, res, req, start_ms,    wire, content, dur, ts) {
  if (res["sent"]) return    # 二重送信防止 (send() 明示呼出 後)

  if (res["_binary_path"] != "" && LIBS_LOADED["binary"]) {
    content = hawk_bin_read(res["_binary_path"])
    res["body"] = ""
    res["header:content-length"] = hawk_bin_length(content)
    wire = response_wire(res)
    # response_wire は body を末尾に付与する仕様 → 末尾は "\r\n\r\n" のみ
    printf "%s", wire |& sock
    fflush(sock)
    # binary content を直接 socket に書く
    printf "%s", content |& sock
    fflush(sock)
  } else {
    wire = response_wire(res)
    printf "%s", wire |& sock
    fflush(sock)
  }
  res["sent"] = 1

  dur = now_ms() - start_ms
  ts  = strftime("%Y-%m-%dT%H:%M:%S%z")
  printf "%s\tINFO\t%s\t%s\t%d\t%d\n", ts, req["method"], req["path"], res["status"], dur
  fflush()
}

function http_send_simple(sock, code, body,    res) {
  delete res
  status(res, code)
  text(res, body)
  printf "%s", response_wire(res) |& sock
  fflush(sock)
}
