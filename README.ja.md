# enghi.el

*[English](README.md) · 日本語*

ローカル専用の Wiki + GTD サーバ [enghi](https://github.com/wakamenod/enghi) を Emacs から使うためのクライアントです。

- ページを Emacs バッファで開いて編集し、`C-c C-c` で保存する
- 入力のたびにサーバへ問い合わせて、全ページを検索する
- どこからでも GTD の Inbox へ1行で送る
- Emacs 内の WebKit で開いたダッシュボードから GTD のタスクを管理する
- Emacs で選んだ項目を、開いているブラウザにも表示する
- dashboard.el の起動画面に、Inbox・今日のタスク・近づいている締切を出す

## 動作要件

| | | |
|---|---|---|
| Emacs | 28.1 以降 | |
| [enghi](https://github.com/wakamenod/enghi) サーバ | 起動していること | |
| `markdown-mode` | 任意 | ページバッファで使用 |
| `consult` | 任意 | キー入力ごとの検索で使用 |
| `dashboard` | 任意 | 起動画面の欄で使用 |

`markdown-mode` と `consult` はなくても動きます。ない場合は、それぞれ `fundamental-mode` と `completing-read` による検索を使います。

## セットアップ

### 1. サーバの起動

```sh
cd ../enghi
make build
./bin/enghi install-agent -load   # launchd で常時起動
```

常時起動せずに試すだけなら、`./bin/enghi serve` でもかまいません。
デフォルトでは `http://127.0.0.1:7777` で待ち受けます。

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. パッケージのインストール

`use-package` で GitHub からインストールします。`:vc` キーワードは Emacs 30 以降で使えます。

```elisp
(use-package enghi
  :vc (:url "https://github.com/wakamenod/enghi.el" :rev :newest)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777"))
```

初めて `C-c n` を押したときにパッケージが読み込まれます。

Emacs 29 では、先に `M-x package-vc-install RET https://github.com/wakamenod/enghi.el RET` でインストールしておきます。

```elisp
(use-package enghi
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777"))
```

Emacs 28 の場合、リポジトリを clone して、そこから読み込みます:

```sh
git clone https://github.com/wakamenod/enghi.el ~/.emacs.d/site-lisp/enghi.el
```

```elisp
(use-package enghi
  :load-path "~/.emacs.d/site-lisp/enghi.el"
  :commands (enghi-find-page enghi-capture enghi-browse-dashboard enghi-search-command)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777")
  :config
  (autoload 'enghi-consult-search "enghi-consult" nil t))
```

更新するときは、そのディレクトリで `git pull` します。

### 3. 動作確認

`M-x enghi-status` でサーバのステータスが返れば、接続できています。
ポート番号を変えた場合は、`enghi-server-url` もそれに合わせてください。

### 4. 最初のページを作成

`C-c n n` を押してタイトルを入力すると、ページバッファが開きます。本文を書いたら `C-c C-c` で保存します。

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

`enghi-page-mode` は `markdown-mode` の上で動きます。バッファの中身はそのままの Markdown です。

| キー | |
|---|---|
| `C-c C-c` | 保存 |
| `C-c C-r` | タイトル変更 |
| `C-c C-t` | タグ編集 |
| `C-c C-l` | ページを選択して `[[link]]` を挿入 |
| `C-c C-o` | ブラウザで開く |
| `C-c C-k` | サーバの内容に戻す |

`[[non-existent page]]` のように、まだないページにもリンクできます。リンクは未解決のまま残り、その名前のページを作ると自動でつながります。

タイトルを変えても、旧タイトルはエイリアスとして残ります。ほかのページにある `[[old title]]` 形式のリンクもそのまま使えます。

## 閲覧しながら編集

WebKit でページを見ているとき (`C-c n b` で開いたときなど) に `E` を押すと、同じページが下のウィンドウに Emacs バッファとして開きます。上のウィンドウで見ながら、下のウィンドウで編集できます。

| キー | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | 表示中のページを下側ウィンドウで編集 |

使えるキーはバッファのヘッダ行に表示されます。表示は画面によって変わり、ページでは `E edit`、GTD リストでは `n next action` や `d done` などが出ます。

GTD リストでは、`j` `k` でこれまでどおりページのカーソルを動かします。タスクを移すキーを押すと、ページのモーダルではなくミニバッファで質問されます。`j`/`k` で行を選んでから、次のキーを押してください。

| キー | 尋ねること | 結果 |
|---|---|---|
| `n` | プロジェクト (`(none)` も可)、コンテキスト機能が有効ならコンテキスト | Next Action |
| `l` | プロジェクト (必須) | Later |
| `w` | 誰・何を待っているか | Waiting For |
| `s` | 日付 (`org-read-date`)、繰り返しルール、任意で最終日 | Scheduled |
| `m` | — | Someday/Maybe |
| `x` | 確認 | 破棄 (Dropped) |
| `d` | — | 完了 (繰り返しタスクは次の回が作られる) |
| `S` | — | 繰り返しタスクの今回をスキップ |
| `t` | 新しいタイトル | 名前を変更 |
| `f` | ページのタイトルとタグ | Wiki ページとして保存し、下側ウィンドウで開く |
| `RET` | — | タスクの詳細ページを開く |

どの質問も既定値はタスクの今の値で、`C-g` を押せば何も変えずに取り消せます。繰り返しルールは、日付に合った候補 (`+1w`、`weekly:fri`、`monthly:25` など) から選ぶか、サーバが受け付ける書式で直接入力します。

`c` と `/` は、enghi のどの画面でも Emacs 側で処理します。`c` は `enghi-capture` でミニバッファから Inbox へ追加し、GTD の画面ならページを再読み込みします。`/` は Emacs で検索し、選んだ結果をこのビューで開きます。

`j` や `k` など、ほかのキーはそのままページへ送られます。

GTD トップ (`/gtd`) では専用のキーを使います。`i` `n` `w` `s` `m` `p` で、それぞれ Inbox、Next Actions、Waiting For、Scheduled、Someday/Maybe、Projects を開きます。

`C-c C-c` で保存すると、サーバが接続中のすべてのクライアントへ更新を配信します。そのページを表示しているビューは自動で再読み込みされ、スクロール位置も保たれます。Emacs 側で再読み込みする必要はありません。

更新を送るのは保存したときだけで、入力中の内容は送りません。

## 保存の競合

編集中に別の経路でページが更新されていた場合は、`ediff` が起動してサーバ版と手元の版を並べて表示します。手元の編集内容はバッファに残るので、差分を確認してから保存し直せます。

すでにあるタイトルに変えようとすると、競合するページを表示して別のタイトルを聞いてきます。本文はそのまま残ります。

## ブラウザ連携

別のディスプレイでブラウザを開いておけば、Emacs で選んだ項目をブラウザにも表示できます。

```
C-c n o
```

サーバは接続中のすべてのタブへ画面遷移のイベントを配信します。サーバが再起動しても、ブラウザは自動で再接続します。

Emacs の中でページを見たい場合は、閲覧用の関数を変更します。

```elisp
(setq enghi-browse-function #'enghi-browse-in-xwidget)  ; デフォルトは #'browse-url
```

`enghi-browse-in-xwidget` は xwidget webkit でページを開き、ビューの周りに少し余白をとります。`xwidget-webkit-browse-url` で開くと、ページの端がフリンジやモードラインに張り付いてしまいます。余白は `enghi-xwidget-padding` で調整できます。整数なら四辺とも同じ幅に、`(horizontal . vertical)` なら左右と上下を別々に指定できます。`0` にするとバッファ全体に広がります。余白がつくのは `enghi` が開いたバッファだけです。

## 起動画面 (dashboard.el)

`enghi-dashboard.el` は、[dashboard](https://github.com/emacs-dashboard/emacs-dashboard) の起動画面に enghi の欄を追加します。agenda の欄の代わりに使えます。

```
enghi:
    Inbox 3
    2 d. ago:   Pay the invoice
    Today:      Submit the report
    In 4 d.:    Renew passport
    Open the dashboard
```

- Inbox の件数。0 でないときは強調します
- 今日のタスク。締切を過ぎたものは先頭に、印をつけて出します
- 近づいている締切 (既定では 7 日以内。サーバの `deadline_warning_days`)

タスクで `RET` を押すとそのタスクを、Inbox の行では Inbox を、最後の行では Web のダッシュボードを開きます。いずれも `enghi-browse-function` で開きます。欄の表示に使うリクエストは `/api/dashboard` への1回だけです。サーバが止まっている、または `enghi-dashboard-timeout` 秒以内に応答しないときは、代わりに `enghi is not running` を1行出します。その行で `RET` を押すと再試行します。近づいている締切に対応していない古いサーバでは、その部分を省いて表示します。

```elisp
(use-package enghi-dashboard
  :after dashboard
  :config
  (add-to-list 'dashboard-items '(enghi . 5) t))
```

数値は、各グループに出すタスクの最大数です。dashboard が必要なのはこのファイルだけで、enghi.el 本体は dashboard に依存しません。

## 設定

| 変数 | デフォルト値 | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | サーバ URL |
| `enghi-request-timeout` | `10` | リクエストのタイムアウト (秒) |
| `enghi-browse-function` | `#'browse-url` | ブラウザで開く関数 |
| `enghi-xwidget-padding` | `(24 . 12)` | `enghi-browse-in-xwidget` の余白 (`(horizontal . vertical)` ピクセル) |
| `enghi-consult-min-input` | `1` | 検索開始に必要な入力文字数 |
| `enghi-dashboard-timeout` | `2` | 起動画面の欄がサーバの応答を待つ時間 (秒) |

パスワードやトークンの設定は不要です。サーバはループバックからの接続だけを受け付けます。

## 開発

```sh
make compile    # バイトコンパイル (警告はエラー扱い)
```

テストは実際のサーバに対して実行します。先に、別のポートでテスト用サーバを起動しておいてください。

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
| `enghi-dashboard.el` | dashboard.el の起動画面に出す欄 |
| `enghi-tests.el` | テスト |
