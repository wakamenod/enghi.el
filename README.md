# enghi.el

[enghi](../enghi) — ローカル専用の Wiki + GTD サーバ — を Emacs から使うためのクライアント。

検索とインデックスは**サーバ側にある**。Emacs 側はそれを持たない。
org-roam が遅い原因は SQLite ではなく (1) Elisp での結果変換、(2) 外部 SQLite プロセスとの IPC、
(3) 保存のたびの全体再クロール、である。enghi はこの3つを Emacs の外に出す構成なので、
**このパッケージは JSON を受け取って表示するだけに徹する。結果を Elisp で捏ねないこと。**

---

## 必要なもの

| | | |
|---|---|---|
| Emacs | 28.1 以上 | |
| [enghi](../enghi) サーバ | 常駐していること | 別リポジトリ |
| `markdown-mode` | 任意 | 記事編集バッファで使う。無ければ `fundamental-mode` |
| `consult` | 任意 | 打鍵ごとの検索。無ければ `completing-read` に落ちる |

認証の設定は無い。サーバが `Host` / `Origin` / `Content-Type` で守っている
(判断の記録は enghi の `docs/DESIGN.md` 4.4 にある)。トークンを置く項目も無い。

---

## セットアップ

### 1. サーバを用意する

```sh
cd ../enghi
make build                      # bin/enghi ができる
./bin/enghi install-agent -load # launchd に登録して常駐させる
```

`install-agent` を使わず手で動かすなら `./bin/enghi serve` でよい。
既定は `http://127.0.0.1:7777`。ブラウザで開けるか確かめておくこと。

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. このパッケージを読み込む

`load-path` に通して `require` するだけ。

```elisp
(add-to-list 'load-path "~/Projects/SideProjects/enghi.el")
(require 'enghi)
(enghi-setup)          ; C-c n にキーマップを置く
```

`use-package` を使っているなら:

```elisp
(use-package enghi
  :load-path "~/Projects/SideProjects/enghi.el"
  :commands (enghi-find-page enghi-capture enghi-agenda enghi-search-command)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777")
  :config
  ;; 打鍵ごとの検索と agenda は必要になってから読み込む
  (autoload 'enghi-agenda "enghi-agenda" nil t)
  (autoload 'enghi-consult-search "enghi-consult" nil t))
```

`straight.el` なら:

```elisp
(straight-use-package
 '(enghi :type built-in :local-repo "~/Projects/SideProjects/enghi.el" :files ("*.el")))
```

### 3. 繋がっているか確かめる

```
M-x enghi-status
```

サーバが居なければ「enghi サーバに接続できない」と出る。ポートを変えているなら
`enghi-server-url` を合わせること。

### 4. 最初の1件を作る

```
C-c n n     enghi-new-page     タイトルを入れると記事バッファが開く
C-c C-c     保存
```

---

## 使う

### キーマップ (`C-c n`)

| キー | コマンド | |
|---|---|---|
| `s` | `enghi-search-command` | 横断検索。consult があれば**打鍵ごとに**サーバを引く |
| `f` | `enghi-find-page` | 記事を選んでバッファで開く |
| `n` | `enghi-new-page` | 新しい記事を作って開く |
| `c` | `enghi-capture` | **どこからでも1行を Inbox へ** |
| `a` | `enghi-agenda` | GTD の一覧 |
| `o` | `enghi-focus-page` | **開いているブラウザタブをその記事へ飛ばす** |
| `b` | `enghi-open-in-browser` | ブラウザで開く |
| `d` | `enghi-browse-dashboard` | ダッシュボードを開く |

### 記事バッファ (`enghi-page-mode`)

`markdown-mode` の上に重なる。本文は Markdown 原文そのもの。

| キー | |
|---|---|
| `C-c C-c` | 保存(楽観ロック付き PUT) |
| `C-c C-r` | 改題。旧タイトルは別名として残り `[[旧タイトル]]` は引き続き解決される |
| `C-c C-t` | タグを付け替える |
| `C-c C-l` | 記事を選んで `[[リンク]]` を挿入 |
| `C-c C-o` | この記事をブラウザで開く |
| `C-c C-k` | サーバの内容に戻す |

`[[まだ無い記事]]` と書いてよい。未解決リンクとして保持され、その名前の記事を作った時点で
自動的に解決される。

### agenda バッファ

| キー | | キー | |
|---|---|---|---|
| `n` | 次の行動 | `d` | 完了 |
| `w` | 他者待ち(相手を聞く) | `k` | 今回は飛ばす |
| `s` | 日付を付ける(tickler) | `x` | 破棄 |
| `l` | 後続の行動 | `f` | **資料にする(記事化)** |
| `m` | いつか/たぶん | `t` | 題名を変える |
| `p` | プロジェクトに紐づける | `C` | コンテキストを付ける |
| `c` | その場で Inbox に追加 | `g` | 更新 |
| `RET` | ブラウザで開く | `q` | 閉じる |

`f` は GTD の clarify で「行動ではなく参照資料だった」と判断したときに使う。
Wiki ページが作られ、元の項目は `filed` になる(完了でも破棄でもない)。

---

## 保存が競合したとき

**409 は2つの異なる意味を持ち、対応がまったく違う。** 混ぜないこと。

| | 何が起きたか | このパッケージの挙動 |
|---|---|---|
| `version_conflict` | 編集中に他の経路(ブラウザなど)で更新された | `ediff` でサーバ側と手元の差分を出す。**手元の入力は捨てない** |
| `title_conflict` | 新しいタイトルが他の記事の正式名/別名と衝突した | 衝突相手を示して別のタイトルを聞き直す。**本文は保持したまま** |

`version` はタグだけを変えたときにも上がる。そうしないと Emacs 側の楽観ロックが
タグ変更を見逃して黙って上書きしてしまうため。

---

## ブラウザとの連携

別ディスプレイにブラウザを開きっぱなしにして、Emacs で選んだものを追従させられる。

```
C-c n o     enghi-focus-page
```

`POST /api/focus` を受けたサーバが、接続している全ブラウザタブに遷移を配信する。
ブラウザ側は指数バックオフで再接続するので、サーバを再起動しても繋がり直す。

表示関数は差し替えられる:

```elisp
(setq enghi-browse-function #'browse-url)                ; 既定(外部ブラウザ)
(setq enghi-browse-function #'xwidget-webkit-browse-url) ; Emacs 内に埋め込む
```

xwidget の既知の弱点は「編集可能テキストエリアとの相互作用」と
「Emacs と WebKit のキー入力の取り合い」だが、**編集はネイティブな Emacs バッファで行うので
その経路を踏まない。** 閲覧用途なら試す価値がある。

---

## 設定できるもの

| 変数 | 既定 | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | ループバック以外はサーバ側の Host 検査で 403 |
| `enghi-request-timeout` | `10` | 同期リクエストのタイムアウト(秒) |
| `enghi-browse-function` | `#'browse-url` | 表示関数 |
| `enghi-consult-min-input` | `1` | この文字数以上でサーバに問い合わせる |
| `enghi-agenda-sections` | inbox / next / waiting / scheduled | agenda に出す節 |

---

## 開発

```sh
make compile    # バイトコンパイルして警告を見る(警告はエラー扱い)
```

テストは**動いているサーバに対して**実行する。本番の DB を汚さないよう、
テスト用の設定で別ポートに立てること:

```sh
cat > /tmp/enghi-test.toml <<'TOML'
port = 7799
db_path = "/tmp/enghi-test/enghi.db"
export_dir = "/tmp/enghi-test/export"
TOML

../enghi/bin/enghi serve --config /tmp/enghi-test.toml &
make test
```

検査している内容:

- **日本語が往復すること** — `url` のバッファは unibyte なので `decode-coding-region` では
  multibyte にならない。ここを間違えると日本語タイトルの記事に一切アクセスできなくなる
  (実際に踏んだ)
- **版が競合したときに手元の入力が消えないこと** — 最悪の壊れ方なので必ず検査する
- `title_conflict` が衝突相手のページを返すこと
- capture、agenda の状態変更が PATCH にマップされること
- **consult の候補がサーバの順序と件数をそのまま使うこと** — Elisp 側で並べ替えたり
  絞り込んだりしていないことの検査

---

## 構成

| ファイル | |
|---|---|
| `enghi.el` | API クライアント、記事の編集、capture、focus、キーマップ |
| `enghi-consult.el` | 打鍵ごとに `/api/search` を叩く consult の非同期ソース |
| `enghi-agenda.el` | org-agenda 風の GTD 一覧 |
| `enghi-tests.el` | ert。動いているサーバに対して実行する |
