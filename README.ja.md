# enghi.el

*[English](README.md) · 日本語*

ローカル専用の Wiki + GTD サーバ [enghi](https://github.com/wakamenod/enghi) の
Emacs クライアント。

- Emacs バッファでページを開いて編集、`C-c C-c` で保存
- キー入力ごとにサーバへ問い合わせるページ横断検索
- どこからでも GTD の Inbox へ1行送信
- Emacs 内の WebKit で開いたダッシュボードから GTD タスクを管理
- 開いているブラウザに Emacs で選択した項目を追従表示

## 動作要件

| | | |
|---|---|---|
| Emacs | 28.1 以降 | |
| [enghi](https://github.com/wakamenod/enghi) サーバ | 起動していること | |
| `markdown-mode` | 任意 | ページバッファで使用 |
| `consult` | 任意 | キー入力ごとの検索で使用 |

`markdown-mode` と `consult` は任意。未導入なら `fundamental-mode` と
`completing-read` による検索にフォールバックする。

## セットアップ

### 1. サーバの起動

```sh
cd ../enghi
make build
./bin/enghi install-agent -load   # launchd で常時起動
```

常時起動せず試すだけなら `./bin/enghi serve` でも動く。
デフォルトでは `http://127.0.0.1:7777` で動作する。

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. パッケージの読み込み

```elisp
(add-to-list 'load-path "~/Projects/SideProjects/enghi.el")
(require 'enghi)
(enghi-setup)          ; C-c n にキーマップを設定
```

`use-package` の場合:

```elisp
(use-package enghi
  :load-path "~/Projects/SideProjects/enghi.el"
  :commands (enghi-find-page enghi-capture enghi-browse-dashboard enghi-search-command)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777")
  :config
  (autoload 'enghi-consult-search "enghi-consult" nil t))
```

`leaf` の場合。`:bind-keymap` は展開時にキーマップを評価するため未読み込みだと失敗する。
キーマップの autoload を追加しておく:

```elisp
(leaf enghi
  :load-path "~/Projects/SideProjects/enghi.el"
  :commands (enghi-find-page enghi-new-page enghi-capture enghi-search-command
             enghi-open-in-browser enghi-focus-page enghi-browse-dashboard enghi-status)
  :init
  (autoload 'enghi-command-map "enghi" nil nil 'keymap)
  (autoload 'enghi-consult-search "enghi-consult" nil t)
  :bind (("C-c n" . enghi-command-map))
  :custom ((enghi-server-url . "http://127.0.0.1:7777")))
```

`straight.el` の場合:

```elisp
(straight-use-package
 '(enghi :type built-in :local-repo "~/Projects/SideProjects/enghi.el" :files ("*.el")))
```

### 3. 動作確認

`M-x enghi-status` でサーバのステータスが返ってくれば接続完了。
ポート番号を変えている場合は `enghi-server-url` を合わせて変更する。

未接続の状態でブラウザを開こうとすると、ブラウザへリクエストを渡す前に Emacs が
エラーを出す (xwidget にそのまま渡すと原因不明の WebKit エラー画面になってしまうため)。

### 4. 最初のページを作成

`C-c n n` を押してタイトルを入力するとページバッファが開く。本文を書いて
`C-c C-c` で保存する。

## 使い方

### キーマップ (`C-c n`)

| キー | コマンド | |
|---|---|---|
| `s` | `enghi-search-command` | ページ横断検索 |
| `f` | `enghi-find-page` | ページを選択して開く |
| `n` | `enghi-new-page` | 新規ページ作成 |
| `c` | `enghi-capture` | Inbox へ1行送信 |
| `o` | `enghi-focus-page` | ブラウザのタブで該当ページを表示 |
| `b` | `enghi-open-in-browser` | ブラウザで開く |
| `d` | `enghi-browse-dashboard` | ダッシュボード (GTD 含む) を開く |

### ページバッファ

`enghi-page-mode` は `markdown-mode` の上で動作する。バッファの内容は素の Markdown
である。

| キー | |
|---|---|
| `C-c C-c` | 保存 |
| `C-c C-r` | タイトル変更 |
| `C-c C-t` | タグ編集 |
| `C-c C-l` | ページを選択して `[[link]]` を挿入 |
| `C-c C-o` | ブラウザで開く |
| `C-c C-k` | サーバの内容に戻す |

`[[non-existent page]]` のように、まだ存在しないページにもリンクできる。未解決リンク
として保持され、その名前でページを作成すると自動でつながる。

タイトルを変更しても旧タイトルはエイリアスとして残る。他ページにある `[[old title]]`
形式のリンクもそのまま機能する。

## 閲覧しながら編集

WebKit でページを閲覧中 (`C-c n b` など) に `E` を押すと、下側のウィンドウにその
ページが Emacs バッファとして開く。上側ウィンドウで閲覧し、下側ウィンドウで編集する。

| キー | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | 表示中のページを下側ウィンドウで編集 |

利用可能なキーは**バッファのヘッダ行に表示される**。表示内容に応じて変化し、ページでは
`E edit`、GTD リストでは `n next action` や `d done` などが表示される。

GTD リストの操作はページ側で処理されるため、`j` `k` `RET` `n` `w` `s` `l` `m` `d`
`S` `f` `t` `x` `c` `/` などのキーはそのままページへ抜ける (`e` で
`xwidget-webkit-edit-mode` に入らずにそのまま押せる)。xwidget 本来のキー送信モード
である `e` もそのまま残してある。

`C-c C-c` で保存すると、サーバが接続中の全クライアントへ更新を配信し、該当ページを
表示しているビューが自動でリロードされる。Emacs から再読み込みする必要はない。
スクロール位置も保持される。

更新が送信されるのは保存時のみ。入力中のテキストは送信されない。

## 保存の競合

編集中に別経路でページが更新された場合、`ediff` が起動してサーバ版とローカル版を
並べて表示する。バッファのローカル編集内容は残るため、差分を確認して再保存できる。

すでに存在するタイトルへ変更しようとすると、競合するページを表示して別タイトルの入力を
促す。本文は保持される。

## ブラウザ連携

別ディスプレイでブラウザを開いておけば、Emacs で選択した項目を追従表示できる。

```
C-c n o
```

サーバが接続中の全タブへ画面遷移イベントを配信する。サーバが再起動しても、
ブラウザは自動で再接続する。

Emacs 内でページを閲覧したい場合は、閲覧関数を変更できる。

```elisp
(setq enghi-browse-function #'enghi-browse-in-xwidget)  ; デフォルトは #'browse-url
```

`enghi-browse-in-xwidget` は xwidget webkit でページを開き、ビューの周囲に適度な余白
を設ける (`xwidget-webkit-browse-url` だとページの端がフリンジやモードラインに張り付
いてしまう)。余白は `enghi-xwidget-padding` で調整できる。整数なら四辺均等、
`(horizontal . vertical)` なら左右と上下を個別に指定できる。`0` にするとバッファ
全体へ広がる。余白が適用されるのは `enghi` が開いたバッファのみである。

## 設定

| 変数 | デフォルト値 | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | サーバ URL |
| `enghi-request-timeout` | `10` | リクエストのタイムアウト (秒) |
| `enghi-browse-function` | `#'browse-url` | ブラウザで開く関数 |
| `enghi-xwidget-padding` | `(24 . 12)` | `enghi-browse-in-xwidget` の余白 (`(horizontal . vertical)` ピクセル) |
| `enghi-consult-min-input` | `1` | 検索開始に必要な入力文字数 |

パスワードやトークンの設定は不要。サーバはループバックからの接続のみを受け付ける。

## 開発

```sh
make compile    # バイトコンパイル (警告はエラー扱い)
```

テストは実サーバに対して実行する。別ポートでテスト用サーバを起動しておく。

```sh
cat > /tmp/enghi-test.toml <<'TOML'
port = 7799
db_path = "/tmp/enghi-test/enghi.db"
export_dir = "/tmp/enghi-test/export"
TOML

../enghi/bin/enghi serve --config /tmp/enghi-test.toml &
make test
```

## 構成

| ファイル | |
|---|---|
| `enghi.el` | API クライアント、ページ編集、キャプチャ、キーマップ |
| `enghi-consult.el` | consult による検索 |
| `enghi-tests.el` | テスト |
