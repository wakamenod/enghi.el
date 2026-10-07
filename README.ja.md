# enghi.el

*[English](README.md) · 日本語*

ローカル専用の Wiki + GTD サーバ [enghi](https://github.com/wakamenod/enghi) を Emacs から使うためのクライアントです。

- ページを Emacs バッファで開いて編集し、`C-c C-c` で保存する
- 入力のたびにサーバへ問い合わせて、全ページを検索する
- どこからでも GTD の Inbox へ1行で送る
- Emacs 内の WebKit で開いたダッシュボードから GTD のタスクを管理する
- Emacs で選んだ項目を、開いているブラウザにも表示する
- dashboard.el の起動画面に、Inbox・今日の予定・作業中のタスク・今日のタスク・近づいている締切を出す

## 動作要件

| | | |
|---|---|---|
| Emacs | 28.1 以降 | |
| [enghi](https://github.com/wakamenod/enghi) サーバ | 起動していること | |
| `markdown-mode` | 任意 | ページバッファで使用 |
| `consult` | 任意 | キー入力ごとの検索で使用 |
| `dashboard` | 任意 | 起動画面の欄で使用 |
| `browse-at-remote` | 任意 | 作業ログに書くコードリンクの URL に使用 |
| `posframe` | 任意 | タスクのリストを posframe に出すときに使用。web 画面の表示には必要 |
| [Claude Code](https://claude.com/claude-code) (`claude`) | 任意 | Inbox に追加した項目を整える |

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

Emacs 29 の `use-package` には `:vc` キーワードがありません。先に `M-x package-vc-install RET https://github.com/wakamenod/enghi.el RET` で一度インストールし、`:vc` を外して設定します。

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

サーバに接続できないときは、ブラウザでページを開こうとすると Emacs 側でエラーメッセージを表示します。

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
| `D` | `enghi-day` | 今日の作業記録を開く (`C-u` で日付を指定) |
| `i` | `enghi-gtd-list` | Inbox などの GTD リストを選んで開く |
| `p` | `enghi-task-list` | GTD のリストを表示し、タスクを1キーで仕分ける |
| `d` | `enghi-peek-dashboard` | web のダッシュボードをフレームの上に表示 |
| `w` | `enghi-peek-working` | 作業中のタスクを最新の作業ログの位置で表示 |
| `l` | `enghi-task-log` | タスクの作業ログを書く |
| `L` | `enghi-task-log-edit` | 作業ログの記録を編集する |
| `t` | `enghi-task-toggle` | タスクを開始・中断する |
| `r` | `enghi-code-link` | カーソル行やリージョンのコードへのリンクをログに書く |
| `R` | `enghi-code-link-with-comment` | `r` と同じ。コメントを書き足してから送る |

### ページバッファ

`enghi-page-mode` は `markdown-mode` の上で動きます。バッファの中身はそのままの Markdown です。

| キー | |
|---|---|
| `C-c C-c` | 保存 |
| `C-c C-r` | タイトル変更 |
| `C-c C-t` | タグ編集 |
| `C-c C-l` | ページを選択して `[[link]]` を挿入 |
| `C-c C-i` | 画像や PDF をアップロードして Markdown を挿入 |
| `C-c C-o` | ブラウザで開く |
| `C-c C-k` | サーバの内容に戻す |

Emacs 29 以降では、`M-x yank-media` でクリップボードの画像 (スクリーンショットなど) をアップロードして挿入できます。ログバッファでも使えます。

`[[non-existent page]]` のように、まだないページにもリンクできます。リンクは未解決のまま残り、その名前のページを作ると自動でつながります。

タイトルを変えても、旧タイトルはエイリアスとして残ります。ほかのページにある `[[old title]]` 形式のリンクもそのまま使えます。

## 閲覧しながら編集

WebKit でページを見ているとき (`C-c n b` で開いたときなど) に `E` を押すと、同じページが下のウィンドウに Emacs バッファとして開きます。上のウィンドウで見ながら、下のウィンドウで編集できます。

| キー | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | 表示中のページを下側ウィンドウで編集 |

使えるキーはバッファのヘッダ行に表示されます。表示は画面によって変わり、ページでは `E edit`、GTD リストでは `n next action` や `d done` などが出ます。

GTD リストでは、`j` `k` でページのカーソルを動かします。タスクを移すキーを押すと、ミニバッファで質問されます。`j`/`k` で行を選んでから、次のキーを押してください。

| キー | 尋ねること | 結果 |
|---|---|---|
| `n` | プロジェクト (`(none)` や新規も可)、コンテキスト機能が有効ならコンテキスト | Next Action |
| `l` | プロジェクト (必須。新規も可) | Later |
| `w` | 誰・何を待っているか | Waiting For |
| `s` | 日付 (`org-read-date`)、繰り返しルール、任意で最終日 | Scheduled |
| `m` | — | Someday/Maybe |
| `x` | 確認 | 破棄 (Dropped) |
| `d` | — | 完了 (繰り返しタスクは次の回が作られる) |
| `S` | — | 繰り返しタスクの今回をスキップ |
| `t` | 新しいタイトル | 名前を変更 |
| `f` | ページのタイトルとタグ | Wiki ページとして保存し、下側ウィンドウで開く |
| `.` | Next Actions にないタスクならプロジェクト | Next へ移して開始 (作業中だったタスクは中断) |
| `RET` | — | タスクの詳細ページを開く |
| `o` | — | タスクの URL をブラウザで開く |

どの質問も既定値はタスクの今の値で、`C-g` を押せば何も変えずに取り消せます。新しいプロジェクトに入れるときは、一覧にない名前を入力します。確認のあと、プロジェクトの「望む結果」を尋ねます。空のままでもかまいません。vertico では、既存のプロジェクトに一部でも一致する名前を入れて `RET` を押すと、そのプロジェクトが選ばれます。入力したとおりの名前で送るには `M-RET` を押します。変更後は、同じ行を選んだままリストを再読み込みします。繰り返しルールは、日付に合った候補 (`+1w`、`weekly:fri`、`monthly:25` など) から選ぶか、サーバが受け付ける書式で直接入力します。

`c` と `/` は、enghi のどの画面でも Emacs 側で処理します。`c` は `enghi-capture` でミニバッファから Inbox へ追加し、GTD の画面ならページを再読み込みします。`/` は Emacs で検索し、選んだ結果をこのビューで開きます。

`j` や `k` など、ほかのキーはそのままページへ送られます。

GTD トップ (`/gtd`) では専用のキーを使います。`i` `n` `w` `s` `m` `p` で、それぞれ Inbox、Next Actions、Waiting For、Scheduled、Someday/Maybe、Projects を開きます。

`C-c C-c` で保存すると、サーバが接続中のすべてのクライアントへ更新を配信します。そのページを表示しているビューは自動で再読み込みされ、スクロール位置も保たれます。Emacs 側で再読み込みする必要はありません。

更新を送るのは保存したときだけで、入力中の内容は送りません。

## 追加した項目を Claude で整える

Claude Code の CLI (`claude`) がインストールされていてログイン済みなら、`C-c n c` で追加した項目を整えます。項目は入力したとおりに、すぐ Inbox に入ります。そのあと `claude -p` が、短いタイトル、詳細を書いたメモ、URL に分けて、項目を更新します。たいてい 10〜30 秒後です。

```
入力:     らいしゅう 歯医者 予約の電話 03-1234-5678 午前中に
タイトル: 歯医者の予約の電話
メモ:     来週、午前中に、03-1234-5678

          Captured as: らいしゅう 歯医者 予約の電話 03-1234-5678 午前中に
```

待つ必要はありません。Claude が動いている間も Emacs は使えます。入力した文はメモの末尾に残ります。Claude が答える前に項目を変更した場合や、Claude が失敗した場合は、追加したときのまま残り、そのことを表示します。Claude は Haiku (`enghi-capture-tidy-model`) で、ツール、MCP サーバ、ユーザーの設定を読まずに動きます。使わないときは `enghi-capture-tidy` を `nil` にします。

## Emacs でタスクを仕分ける

`C-c n p` (`enghi-task-list`) は GTD のリストを表示し、そのタスクを1キーで操作できるようにします。ウィンドウは使いません。リストはエコーエリアか posframe (後述) に出ます。

```
→ Someday: 新しい椅子を買う
Inbox 4 · Next 12 · Waiting 3 · Scheduled 5 · Later 2 · Someday 30
›   水道屋に電話する                                  3 d. ago
    パスポートを更新する                              1 d. ago
    …
──────────────────────────────────────────────────────────────────────────
 Move to          Finish      Task          View
  n  Next          d  Done     .  Start      RET  Details
  l  Later         S  Skip     t  Rename     o    Open URL
  w  Waiting       x  Drop     f  File
  s  Scheduled
  m  Someday

  j/k  Move    Tab  List    g  Refresh    q  Quit
```

開くと、Inbox を古い順に表示します。Inbox が空なら Next Actions を表示します。`j` と `k` (または `C-n` と `C-p`) でタスクを選び、`Tab` と `S-Tab` で Inbox、Next、Waiting、Scheduled、Later、Someday を切り替えます。Next は Next Actions リストなので、web 画面と同じく、日付が来た Scheduled のタスクもここに出ます。作業中のタスクには `▶` が付きます。タスクの右には、Inbox なら追加してからの日数、Waiting なら待っている相手、Scheduled なら日付、それ以外はプロジェクトを出します。

操作のキーは xwidget の GTD リストと同じで、ミニバッファで同じことを尋ねます。違うのは2つです。`f` はタスクをページとして保存しますが、ページは開きません。`RET` はタスクのページを、リストの上に peek (「web 画面を posframe で見る」を参照) で出します。peek で `q` を押すとリストに戻ります。posframe や xwidgets がない場合は、`enghi-browse-function` で開きます。キーを押すとリストを読み直し、カーソルは同じ位置に残ります。結果はリストの上に出ます。質問は `C-g` で取り消せます。リストで `q` か `C-g` を押すと終わり、Inbox の残りの件数を表示します。

`.` はタスクの作業を今すぐ開始します。Next Actions にないタスクは先に Next へ移すので、`n` と同じくプロジェクトを尋ねます。日付が来た Scheduled のタスクは、日付と繰り返しを残したまま開始します。

vertico-posframe などで補完を posframe に出している場合は、リストも posframe に出せます。質問と同じ場所に出るので、目線が動きません。posframe 自体は入力を受けません。キーは vertico-posframe と同じく、フレーム側で読みます。質問している間、posframe は隠れます。

```elisp
(setq enghi-triage-display 'posframe)
;; 任意: vertico-posframe と見た目を揃える
(setq enghi-posframe-border-width 5)
(set-face-background 'enghi-posframe-border "#323445")
```

キーは face `enghi-triage-key` でキーキャップ風に、列の見出しは `enghi-triage-heading` で描きます。位置は `enghi-triage-posframe-poshandler` で決まります。既定では横は中央、上端はフレームの高さの `enghi-triage-posframe-top` (既定 0.1) の位置です。posframe では、どのリストを出しても、タスクが何件あっても大きさが変わらないので、位置も動きません。一度に出すタスクの数は `enghi-task-list-height` (既定 15)、タイトルの列幅は `enghi-task-list-title-width` (既定 48)、右の列の幅は `enghi-task-list-side-width` (既定 20) で変えられます。列幅より長い文字は「…」で切ります。posframe がない場合や、グラフィカルなフレームでない場合は、エコーエリアに出ます。

## web 画面を posframe で見る

`C-c n d` (`enghi-peek-dashboard`) は、web のダッシュボードをフレームの中央に重ねて表示します。`C-c n w` (`enghi-peek-working`) は、作業中のタスクの Clarify ページを、最新の作業ログまでスクロールして表示します。web 画面そのものなので、作業ログのダイアグラムやコードもブラウザと同じように表示されます。ウィンドウは使いません。posframe と、xwidgets 付きでビルドした Emacs が必要です。

| キー | |
|---|---|
| `j` / `k` | スクロール (`C-n`/`C-p` や矢印キーも可) |
| `SPC` / `S-SPC` | 1画面ずつスクロール (`C-v`/`M-v` や `DEL` も可) |
| `<` / `>` | ページの先頭 / 末尾 |
| `z` / `Z` | 見えている一番上の Mermaid の図を、ページのビューアで開く。開いている間は次 / 前の図へ |
| `+` / `-` / `0` | ビューアで拡大 / 縮小 / 図の全体を表示 |
| `h` `j` `k` `l` | ビューアで図を動かす (矢印キーも可) |
| `d` / `w` | ダッシュボード / 作業中のタスクを表示 |
| `r` | 再読み込み |
| `E` | 閉じて、ページをウィンドウで開く (`enghi-browse-in-xwidget`) |
| `o` | 閉じて、ページをブラウザで開く |
| `q` | 図のビューアを閉じる。開いていなければ peek を閉じる |

ほかのキーを押すと閉じて、そのキー本来の操作をします。ページは変更に自動で追従するので、開いている間に書いた作業ログもすぐ表示されます。表示は使い回すので、2回目からは速く開きます。

大きさは `enghi-peek-size` (既定 `(0.8 . 0.85)`、フレームに対する割合)、位置は `enghi-peek-poshandler` で決まります。枠はタスクのリストと共通です。

## 保存の競合

編集中に別の経路でページが更新されていた場合は、`ediff` が起動してサーバ版と手元の版を並べて表示します。手元の編集内容はバッファに残るので、差分を確認してから保存し直せます。

すでにあるタイトルに変えようとすると、競合するページを表示して別のタイトルを聞いてきます。本文はそのまま残ります。

## 作業ログ

作業ログは GTD のタスクごとの記録です。試したこと、わかったこと、決めたことを日時付きの Markdown で書き足していきます。タスクの開始・中断も記録され、最後が開始のタスクは「作業中」になります。使うには、作業ログに対応したサーバ (v0.2.0 より後) が必要です。

次のコマンドは、どれも最初にタスクを尋ねます。候補は未完了のタスクだけで、作業中のタスクが `▶` 付きで先頭に並びます。xwidget で Clarify ページ (`/gtd/clarify/…`) を開いていれば、そのタスクが初期値です。開いていなければ、作業中のタスクが1つだけのとき、それが初期値になります。

| コマンド | |
|---|---|
| `enghi-task-log` | 新しい記録を書くバッファを開く |
| `enghi-task-log-edit` | 記録を新しい順に並べ、選んだものを編集する |
| `enghi-task-log-delete` | 記録を選び、確認してから削除する |
| `enghi-task-start` / `enghi-task-pause` | タスクの開始・中断を記録する。`C-u` 付きなら1行のコメントを添える |
| `enghi-task-toggle` | 作業中なら中断、それ以外なら開始 |
| `enghi-code-link` | カーソル行やリージョンのコードへのリンクをログに書く |
| `enghi-code-link-with-comment` | リンクをログバッファで開き、コメントを書き足してから送る |

作業中のタスクを開始したり、作業中でないタスクを中断したりしても何も変わりません。その場合はそう表示します。コメントを添えていれば、コメントだけは記録として残ります。

作業中にできるタスクは1つだけです。タスクを開始すると、それまで作業中だったタスクは中断され、そのことを表示します (`▶ Started: 報告書を書く (⏸ Paused: バグを直す)`)。これには v0.3.12 より後のサーバが必要です。古いサーバでは、複数のタスクを同時に作業中にできます。

### ログバッファ

`enghi-log-mode` は、ページバッファと同じく `markdown-mode` の上で動きます。

| キー | |
|---|---|
| `C-c C-c` | 送信してバッファを閉じる。`C-u` 付きなら、続けてその記録をブラウザで開く |
| `C-c C-k` | 破棄 (書きかけなら確認する) |
| `C-c C-l` | ページを選択して `[[link]]` を挿入 |
| `C-c C-i` | 画像や PDF をアップロードして Markdown を挿入 |
| `C-c C-o` | タスクのページを開く (編集中はその記録の位置) |
| `C-c C-d` | 編集中の記録を削除 |

送信前の記録はバッファに残るので、同じタスクでもう一度 `C-c n l` を押せば続きから書けます。編集中の記録がほかの場所で変更されていた場合は、ページと同じように、サーバ側と手元の内容を `ediff` で並べます。

### コードリンク

`enghi-code-link` は、コードを読んだ場所を書き留めるコマンドです。どのファイルからでも、次のような記録をタスクのログに書き足します。

````markdown
[internal/web/server.go L120-134](https://github.com/you/repo/blob/3f2a…/internal/web/server.go#L120-L134)

```go
func (s *Server) routes() {
	…
}
```
````

- リージョンがあれば、その行範囲へのリンクの下にコードを載せます。共通のインデントは取り除きます。リージョンがなければ、現在の行へのリンクだけを書きます。
- パスはプロジェクト (または VC) のルートからの相対パスです。コードブロックの言語はメジャーモードから決めます (`go-ts-mode` → `go`、`emacs-lisp-mode` → `elisp`)。
- URL は、[browse-at-remote](https://github.com/rmuslimov/browse-at-remote) がインストールされていればそれで作ります。`browse-at-remote-prefer-symbolic` を `nil` にすると、リンク先がブランチではなくコミットに固定されます。browse-at-remote がない場合や、リモートのわからないファイルでは、パスと行をリンクなしで書きます。

作業ログの記録も検索にかかります。結果には `Log` と表示され、選ぶとタスクのページがその記録の位置で開きます。

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

`enghi-browse-in-xwidget` は xwidget webkit でページを開き、ビューの周りに少し余白をとります。余白は `enghi-xwidget-padding` で調整できます。整数なら四辺とも同じ幅に、`(horizontal . vertical)` なら左右と上下を別々に指定できます。`0` にするとバッファ全体に広がります。余白がつくのは `enghi` が開いたバッファだけです。

## 起動画面 (dashboard.el)

`enghi-dashboard.el` は、[dashboard](https://github.com/emacs-dashboard/emacs-dashboard) の起動画面に enghi の欄を追加します。agenda の欄の代わりに使えます。

```
enghi:
    Inbox 3
    All day     祝日  (祝日)
    09:00–09:30 朝会  (職場)
    11:00–12:00 設計レビュー  (職場)  @会議室A
    Working:    報告書を書く  (Q3)  since 10:42 (1h 5m)
    2 d. ago:   Pay the invoice
    Today:      Submit the report
    In 4 d.:    Renew passport
    Open the dashboard
    Open the day page
```

- Inbox の件数。0 でないときは強調します
- 今日のカレンダーの予定。終日の予定を先に、ほかは開始時刻の順に出します。終わった予定は薄く表示し、進行中の予定は時刻を強調します
- 作業中のタスク。サーバが作業の開始時刻を送る場合は、その時刻と経過時間も出します。前日以前に始めた作業は日付つきで目立たせるので、中断し忘れに気づけます
- 今日のタスク。締切を過ぎたものは先頭に、印をつけて出します
- 近づいている締切 (既定では 7 日以内。サーバの `deadline_warning_days`)

タスクで `RET` を押すとそのタスクを、Inbox の行では Inbox を開きます。予定の行では、その予定から作ったタスクを開きます。タスクがなければ今日の作業記録ページを開きます。最後の2行は Web のダッシュボードと今日の作業記録ページを開きます。いずれも `enghi-browse-function` で開きます。サーバが止まっている、または `enghi-dashboard-timeout` 秒以内に応答しないときは、代わりに `enghi is not running` を1行出します。その行で `RET` を押すと再試行します。予定・作業中のタスク・近づいている締切に対応していない古いサーバでは、その部分を省いて表示します。

予定の時刻と作業の開始時刻は、Emacs のローカル時刻で表示します。欄はタイマーでは更新しません。更新するにはダッシュボードを再表示してください。

```elisp
(use-package enghi-dashboard
  :after dashboard
  :config
  (add-to-list 'dashboard-items '(enghi . 5) t))
```

数値は、各グループに出す行の最大数です。dashboard が必要なのはこのファイルだけで、enghi.el 本体は dashboard に依存しません。

## 設定

| 変数 | デフォルト値 | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | サーバ URL |
| `enghi-request-timeout` | `10` | リクエストのタイムアウト (秒) |
| `enghi-browse-function` | `#'browse-url` | ブラウザで開く関数 |
| `enghi-xwidget-padding` | `(24 . 12)` | `enghi-browse-in-xwidget` の余白 (`(horizontal . vertical)` ピクセル) |
| `enghi-consult-min-input` | `1` | 検索開始に必要な入力文字数 |
| `enghi-dashboard-timeout` | `2` | 起動画面の欄がサーバの応答を待つ時間 (秒) |
| `enghi-triage-display` | `echo-area` | タスクのリストを出す場所。`echo-area` か `posframe` |
| `enghi-task-list-title-width` | `48` | タスクのリストでタイトルが使う列幅 |
| `enghi-task-list-side-width` | `20` | タスクのリストで右の列 (プロジェクトや日付など) が使う列幅 |
| `enghi-posframe-border-width` | `1` | posframe の枠の幅 (ピクセル)。色は face `enghi-posframe-border` の背景色 |
| `enghi-peek-size` | `(0.8 . 0.85)` | web 画面を表示する posframe の大きさ。フレームの幅と高さに対する割合 |
| `enghi-capture-tidy` | `t` | `claude` があれば、追加した項目を Claude で整える |
| `enghi-claude-program` | `"claude"` | Claude Code の CLI |
| `enghi-capture-tidy-model` | `"haiku"` | 項目を整えるモデル |
| `enghi-code-link-url-function` | `#'enghi--browse-at-remote-url` | コードリンクの URL を返す関数。URL がなければ `nil` を返す |

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
| `enghi-log.el` | GTD タスクの作業ログ、コードリンク |
| `enghi-triage.el` | タスクを仕分けるリスト (エコーエリアか posframe) |
| `enghi-peek.el` | web 画面を posframe で表示 |
| `enghi-tidy.el` | 追加した項目を Claude で整える |
| `enghi-consult.el` | consult による検索 |
| `enghi-dashboard.el` | dashboard.el の起動画面に出す欄 |
| `enghi-tests.el` | テスト |
