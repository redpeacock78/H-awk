# SPDX-License-Identifier: MIT
# core/plugin.awk -- プラグイン管理 (設定ドリブン関数)
#
# 起動時に bin/hawk が plugins/<name>/manifest.awk と plugins/<name>/<name>.awk を
# 既に -f でロードしている。この core はそれら関数の登録と hook 呼出を担当する。
#
# 規約:
#   plugin_<name>_manifest(meta)        -- メタ情報を meta[] に書く
#   plugin_<name>_<hook>(req, res)      -- hook の実装
#                                          戻り値 1 = pre_request abort
#
# データ構造:
#   PLUGINS[name, "version" / "hooks" / "api" / "config_keys"]
#   HOOKS[hook_name, i]      = 関数名 (登録順)
#   HOOKS_COUNT[hook_name]   = 件数
#
# config_keys を満たさなかった場合 PLUGIN_REGISTER_ERROR=1 を立てる
# (起動時 main loop が exit 1 で判定する)

function plugin_discover(   cmd, pname, func_name, meta, root, disabled, dirs, n, i, dir) {
  if (ENVIRON["HAWK_PLUGIN_DIRS"] != "") {
    n = split(ENVIRON["HAWK_PLUGIN_DIRS"], dirs, "\n")
  } else {
    root = (ENVIRON["HAWK_LIB"] != "" ? ENVIRON["HAWK_LIB"] : ".") "/plugins"
    cmd = "ls " _shellquote(root) " 2>/dev/null"
    while ((cmd | getline pname) > 0) {
      if (pname == "" || pname ~ /^\./) continue
      dirs[++n] = root "/" pname
    }
    close(cmd)
  }
  for (i = 1; i <= n; i++) {
    dir = dirs[i]
    sub(/\/+$/, "", dir)
    pname = dir
    sub(/^.*\//, "", pname)
    if (pname == "" || pname ~ /^\./) continue
    disabled = dir "/.disabled"
    if ((getline _ < disabled) >= 0) {
      close(disabled)
      continue
    }
    close(disabled)

    func_name = "plugin_" pname "_manifest"
    delete meta
    if (!(func_name in FUNCTAB)) {
      print "plugin: function not found: " func_name > "/dev/stderr"
      continue
    }
    @func_name(meta)
    plugin_register(pname, meta)
  }
}

function plugin_register(pname, meta,    keys, n, j, hooks, m, hook_name, k) {
  PLUGINS[pname, "version"]     = meta["version"]
  PLUGINS[pname, "hooks"]       = meta["hooks"]
  PLUGINS[pname, "api"]         = meta["api"]
  PLUGINS[pname, "config_keys"] = meta["config_keys"]

  if (meta["config_keys"] != "") {
    n = split(meta["config_keys"], keys, ",")
    for (j = 1; j <= n; j++) {
      k = trim(keys[j])
      if (!env::has(k)) {
        if (!PLUGIN_QUIET) log_error("plugin " pname " missing env: " k)
        PLUGIN_REGISTER_ERROR = 1
      }
    }
  }

  if (meta["hooks"] != "") {
    m = split(meta["hooks"], hooks, ",")
    for (j = 1; j <= m; j++) {
      hook_name = trim(hooks[j])
      if (hook_name == "") continue
      HOOKS[hook_name, ++HOOKS_COUNT[hook_name]] = "plugin_" pname "_" hook_name
    }
  }
}

# call_hooks: 指定 hook を登録順に呼ぶ。
# pre_request では戻り値 1 で abort して 1 を返す。
# 他は常に 0 を返す (全 hook を走らせる)。
function call_hooks(hook_name, req, res,    i, n, fn, ret) {
  if (!(hook_name in HOOKS_COUNT)) return 0
  n = HOOKS_COUNT[hook_name]
  for (i = 1; i <= n; i++) {
    fn = HOOKS[hook_name, i]
    ret = @fn(req, res)
    if (hook_name == "pre_request" && ret == 1) return 1
  }
  return 0
}
