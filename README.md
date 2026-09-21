# enghi.el

ローカル専用の Wiki + GTD サーバ [enghi](../enghi) を Emacs から使うためのクライアントです。

- 記事を Emacs のバッファで開いて編集し、`C-c C-c` で保存
- 打鍵ごとにサーバを引く横断検索
- どこからでも1行を GTD の Inbox へ
- GTD のタスクは Emacs 内の webkit に出したダッシュボードから扱う
- Emacs で選んだものを、開きっぱなしのブラウザに表示させる

## 必要なもの

| | | |
|---|---|---|
| Emacs | 28.1 以上 | |
| [enghi](../enghi) サーバ | 常駐していること | |
| `markdown-mode` | 任意 | 記事バッファで使います |
| `consult` | 任意 | 打鍵ごとの検索に使います |

`markdown-mode` と `consult` は無くても動きます。それぞれ `fundamental-mode`、
`completing-read` での検索になります。

## セットアップ

### 1. サーバを起動する

```sh
cd ../enghi
make build
./bin/enghi install-agent -load   # launchd で常駐させる
```

常駐させずに試すだけなら `./bin/enghi serve` でも構いません。
既定では `http://127.0.0.1:7777` で動きます。

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. 読み込む

```elisp
(add-to-list 'load-path "~/Projects/SideProjects/enghi.el")
(require 'enghi)
(enghi-setup)          ; C-c n にキーマップを置きます
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

`leaf` の場合。`:bind-keymap` は展開時にキーマップを `eval` してしまい未ロードだと
失敗するので、キーマップの autoload を張ります:

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

### 3. 動作を確かめる

`M-x enghi-status` でサーバの状態が返ってくれば繋がっています。
ポートを変えている場合は `enghi-server-url` を合わせてください。

繋がらない状態でブラウザを開こうとした場合は、ブラウザに投げる前に
Emacs 側でエラーになります（xwidget に投げると WebKit のエラーページが
表示されるだけで、原因が分からないため）。

### 4. 最初の記事を書く

`C-c n n` でタイトルを入力すると記事バッファが開きます。本文を書いて `C-c C-c` で保存します。

## 使い方

### キーマップ（`C-c n`）

| キー | コマンド | |
|---|---|---|
| `s` | `enghi-search-command` | 横断検索 |
| `f` | `enghi-find-page` | 記事を選んで開く |
| `n` | `enghi-new-page` | 新しい記事を作る |
| `c` | `enghi-capture` | 1行を Inbox へ |
| `o` | `enghi-focus-page` | ブラウザのタブをその記事へ飛ばす |
| `b` | `enghi-open-in-browser` | ブラウザで開く |
| `d` | `enghi-browse-dashboard` | ダッシュボード（GTD もここ）を開く |

### 記事バッファ

`markdown-mode` に `enghi-page-mode` が重なります。本文は Markdown の原文そのものです。

| キー | |
|---|---|
| `C-c C-c` | 保存 |
| `C-c C-r` | タイトルを変更 |
| `C-c C-t` | タグを編集 |
| `C-c C-l` | 記事を選んで `[[リンク]]` を挿入 |
| `C-c C-o` | ブラウザで開く |
| `C-c C-k` | サーバの内容に戻す |

`[[まだ無い記事]]` のように、存在しない記事へのリンクも書けます。未解決リンクとして
保持され、その名前の記事を作った時点で自動的に繋がります。

タイトルを変更すると、旧タイトルは別名として残ります。`[[旧タイトル]]` と書かれた
他の記事のリンクはそのまま機能します。

## 見ながら書く

webkit で記事を開いている状態（`C-c n b` など）で `E` を押すと、その記事が
下の窓に Emacs バッファとして開きます。上が表示、下が編集です。

| キー | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | 表示中の記事を下の窓で編集する |

`e` は xwidget 本来の「キーをページ側へ渡す」モードなので潰していません。

`C-c C-c` で保存すると、サーバが接続中の全クライアントに更新を配信し、その記事を
表示している画面は自分で読み込み直します。Emacs から更新を掛ける必要はありません。
読んでいた位置はそのまま持ち越されます。

配信されるのは保存の時点です。打っている途中の内容は送られません。

## 保存が競合したとき

編集中に他の経路で更新されていた場合は、`ediff` でサーバ側と手元の内容を並べます。
手元の編集内容はバッファに残ったままなので、見比べてから保存し直せます。

タイトルを変更しようとして既存の記事と重複した場合は、衝突した相手を表示して別の
タイトルを尋ねます。本文はそのまま保持されます。

## ブラウザとの連携

別のディスプレイにブラウザを開いたままにしておくと、Emacs で選んだものを追従させられます。

```
C-c n o
```

サーバが接続中の全タブに遷移を配信します。サーバを再起動してもブラウザ側から繋ぎ直します。

記事を Emacs 内に表示したい場合は、表示関数を差し替えられます。

```elisp
(setq enghi-browse-function #'enghi-browse-in-xwidget)  ; 既定は #'browse-url
```

`enghi-browse-in-xwidget` は xwidget の webkit で開き、ビューの周りに少し余白を
残します（`xwidget-webkit-browse-url` だとページの縁がフリンジやモードラインに
貼り付きます）。余白は `enghi-xwidget-padding` で変えられます。整数なら四方に同じだけ、
`(横 . 縦)` なら左右と上下を別々に。`0` にするとバッファいっぱいに広がります。
余白は enghi が開いたバッファにだけ効きます。

## 設定

| 変数 | 既定 | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | サーバの URL |
| `enghi-request-timeout` | `10` | リクエストのタイムアウト（秒） |
| `enghi-browse-function` | `#'browse-url` | ブラウザで開くときの関数 |
| `enghi-xwidget-padding` | `(24 . 12)` | `enghi-browse-in-xwidget` の余白、`(左右 . 上下)` ピクセル |
| `enghi-consult-min-input` | `1` | 何文字入力したら検索を始めるか |

パスワードやトークンの設定はありません。サーバはループバックからの接続のみを受け付けます。

## 開発

```sh
make compile    # バイトコンパイル（警告はエラー扱い）
```

テストは動いているサーバに対して実行します。別ポートにテスト用のサーバを立ててください。

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
| `enghi.el` | API クライアント、記事の編集、capture、キーマップ |
| `enghi-consult.el` | consult を使った検索 |
| `enghi-tests.el` | テスト |
