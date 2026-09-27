# The order of demo/scenes/insert-image.el, and how long each step is held.
# Read by demo/record.sh, which defines `e' (run a form in the demo Emacs)
# and `say' (a caption in the echo area).
#
#   demo/record.sh insert-image
#
# Step 5 replaces the clipboard with a picture.

say "insert-image ブランチ: ページとログに画像・PDF を Emacs から挿入する"; sleep 5
e "(demo-frame)"; sleep 1

say "1. ページバッファで C-c C-i。ファイルを選ぶとアップロードして Markdown を挿入"; sleep 5
e '(demo-play (quote ((:eval (demo-left)) "\n" 0.5 (:run "C-c C-i") 2.5 "upload-flow.png" 1.5 (:key "RET"))))'; sleep 7

say "2. C-c C-c で保存すると、ブラウザ側に画像が表示される"; sleep 4
e '(demo-play (quote ((:run "C-c C-c") 1.5 (:eval (demo-reload-right)))))'; sleep 7

say "3. PDF はリンクとして入る"; sleep 3
e '(demo-play (quote ("\n\n設計メモ: " 0.5 (:run "C-c C-i") 2.5 "design-notes.pdf" 1.5 (:key "RET") 2 (:run "C-c C-c") 1.5 (:eval (demo-reload-right)))))'; sleep 11

say "4. 対応していない種類 (SVG) は送る前に弾く"; sleep 4
e '(demo-play (quote ((:run "C-c C-i") 2.5 "logo.svg" 1.5 (:key "RET") 1 (:eval (demo-say-refusal)))))'; sleep 9

say "5. スクリーンショットをクリップボードにコピーして M-x yank-media"; sleep 4
e "(demo-copy-screenshot)"; sleep 1
e '(demo-play (quote ("\n\nテスト結果:\n\n" 0.5 (:key "M-x") 1 "yank-media" 1.5 (:key "RET") 3 (:run "C-c C-c") 1.5 (:eval (demo-reload-right)))))'; sleep 14

say "6. タスクの作業ログでも同じ: C-c C-i と yank-media"; sleep 4
e '(demo-play (quote ((:eval (demo-open-log)) 1.5 "図を更新した。\n\n" 0.5 (:run "C-c C-i") 2.5 "upload-flow.png" 1.5 (:key "RET") 1.5 "\n\n" (:key "M-x") 1 "yank-media" 1.5 (:key "RET") 3 (:run "C-c C-c"))))'; sleep 20
e '(demo-browse-right (format "/gtd/clarify/%s" (alist-get (quote id) demo-task)))'; sleep 4
e "(demo-scroll-right-to-bottom)"; sleep 8

say "画像と PDF の挿入: C-c C-i と M-x yank-media"; sleep 5
e "(demo-report)"; sleep 1
e '(demo-save-log "/tmp/enghi-demo-insert-image-log.txt")'; sleep 1
