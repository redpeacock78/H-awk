# hawk DSL サンプルアプリ

このディレクトリは hawk DSL 構文を使った例となるサンプルアプリを示します。

## 概要

`app.awk` は todo 管理アプリの実装例です。以下の DSL 機能を使用しています：

### 1. ドット記法（Dot Notation）

```awk
hawk.app.get("/", "todo_index")
hawk.res.text("Hello")
```

ドット記法は自動的に `hawk::dispatch()` に変換されます：

```awk
# DSL
hawk.app.get("/", "todo_index")

# 変換後
hawk::dispatch("app", "get", "/", "todo_index")
```

### 2. let 宣言

```awk
let items = []
let count = 0
let message = "Hello"
```

`let` は gawk のローカル変数を定義する記法です。スコープ管理を明確にします：

```awk
# DSL
let id = ctx.req.param("id")

# gawk では関数パラメータでスコープ管理
function func(  id) {  # 空パラメータは gawk のローカル変数
  id = ctx.req.param("id")
}
```

## 実行方法

```bash
bin/hawk examples/dsl/app.awk
```

## ルーティング

- `GET /` → `todo_index()` 全 todo 一覧表示
- `GET /todos/:id` → `todo_show()` 特定の todo を表示
- `POST /todos` → `todo_add()` 新しい todo を追加
- `DELETE /todos/:id` → `todo_delete()` todo を削除

## API 例

### 全 todo 取得
```
GET /
```

### 特定の todo 表示
```
GET /todos/1
```

### 新規 todo 追加
```
POST /todos
Content-Type: application/x-www-form-urlencoded

title=Buy+milk
```

### todo 削除
```
DELETE /todos/1
```

## DSL 構文の便利さ

DSL 構文により、このアプリは以下の利点があります：

1. **可読性**: ドット記法で hawk API が直感的に見える
2. **簡潔性**: let 宣言でスコープを明確に
3. **保守性**: 従来の gawk のうっかりグローバル汚染を防止
4. **表現力**: AWK の汎用性を保ちながら web フレームワークのような構文

## 内部処理

プリプロセッサが以下のように自動変換します：

- ドット記法 → `hawk::dispatch()` 関数呼び出し
- `let var = val` → gawk のローカル変数宣言（関数パラメータ）
- `ctx.req.param()` → `hawk::ctx_req_param()` など

詳細は `/lib/dsl/` の transformer を参照してください。
