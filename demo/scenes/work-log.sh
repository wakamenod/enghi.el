# The order of demo/scenes/work-log.el, and how long each step is held.
# Read by demo/record.sh, which defines `e' (run a form in the demo Emacs)
# and `say' (a caption in the echo area).
#
#   demo/record.sh work-log
#
# Every step that opens a minibuffer is one `demo-play': Emacs does not
# answer emacsclient while a minibuffer is open, so the typing and the RET
# are played on timers from inside the same call.  The sleeps after it
# cover what it plays.

say "work-log ブランチ: enghi のタスク作業ログを Emacs から書く"; sleep 5
e "(demo-frame)"; sleep 1

say "1. C-c n t でタスクを開始する (候補は未完了タスクだけ)"; sleep 4
e '(demo-play (quote ((:eval (demo-left)) (:run "C-c n t") 3 "2文字" 1.5 (:key "RET") 1 (:eval (demo-reload-right)))))'; sleep 9

say "2. C-c n l で作業ログを書く。作業中のタスクが ▶ 付きで先頭、しかも初期値"; sleep 5
e '(demo-play (quote ((:run "C-c n l") 3.5 (:key "RET") 1.5 "## 原因\n\n2文字のクエリは FTS5 を通らず LIKE に落ちる。log はその経路に入っていなかった。\n" 1.5 (:say "C-c C-c で送信してバッファを閉じる") 2.5 (:run "C-c C-c"))))'; sleep 22

say "3. コードを読みながら、リージョンを選んで C-c n r"; sleep 4
e '(demo-play (quote ((:eval (demo-select-lines 121 133)) 3 (:run "C-c n r") 3 (:key "RET"))))'; sleep 9
say "パーマリンク (browse-at-remote) とコードブロックが作業中タスクのログに入った"; sleep 5

say "C-c n R ならログバッファで開いて、コメントを書き足してから送る"; sleep 4
e '(demo-play (quote ((:eval (demo-select-lines 144 146)) 2.5 (:run "C-c n R") 2.5 (:key "RET") 2 "done のタスクは start できない。ここで弾いている。" 2.5 (:run "C-c C-c"))))'; sleep 19

say "4. タスクの Clarify ページ: 開始・メモ・コードリンクが並ぶ"; sleep 3
e "(demo-browse-right (format \"/gtd/clarify/%s\" (demo-task-id \"ログ検索の2文字クエリを直す\")))"; sleep 4
e "(demo-scroll-right-to-bottom)"; sleep 9

say "xwidget で別タスクの Clarify ページを開いていれば、そちらがピッカーの初期値"; sleep 4
e "(demo-browse-right (format \"/gtd/clarify/%s\" (demo-task-id \"リリースノートを書く\")))"; sleep 4
e '(demo-play (quote ((:run "C-c n l") 4 (:key "RET") 3 (:say "何も書いていないので C-c C-k はそのまま閉じる") 2.5 (:run "C-c C-k"))))'; sleep 14

say "5. 検索は作業ログも対象。Log として出て、そのエントリーの位置で開く"; sleep 4
e '(demo-play (quote ((:run "C-c n s") 1 "FTS5" 4 (:key "RET"))))'; sleep 10

say "6. エントリーの編集: C-c n L でタスクとエントリーを選ぶ"; sleep 4
e '(demo-play (quote ((:eval (demo-left)) (:run "C-c n L") 3 (:key "RET") 3.5 (:key "RET") 2 (:key "M->") " (修正済み)" 2 (:eval (demo-edit-elsewhere)) 3.5 (:say "C-c C-c で保存しようとすると…") 2 (:run "C-c C-c"))))'; sleep 26
say "上書きせず、サーバー側と手元の内容を ediff で並べる"; sleep 8
e "(demo-close-ediff)"; sleep 2

say "7. C-c n t で中断。作業中のタスクには中断を送る"; sleep 4
e '(demo-play (quote ((:run "C-c n t") 3 (:key "RET"))))'; sleep 7
say "同じタスクをもう一度 enghi-task-pause: 何も変わらないことを報告する"; sleep 4
e "(demo-pause-again)"; sleep 6
e "(demo-browse-right (format \"/gtd/clarify/%s\" (demo-task-id \"ログ検索の2文字クエリを直す\")))"; sleep 3
e "(demo-scroll-right-to-bottom)"; sleep 7

say "作業ログは Emacs から: C-c n l / L / r / R / t"; sleep 6
e '(demo-save-log "/tmp/enghi-demo-work-log-log.txt")'; sleep 1
