# emacs は PATH に無いことがある(emacs-plus は Cellar に置かれる)。
# 見つからなければ Homebrew の最新版を探す。EMACS=... で上書きできる。
EMACS ?= $(shell command -v emacs 2>/dev/null || \
           ls -1d /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort -V | tail -1 || \
           echo emacs)

# テストは**動いている enghi サーバ**に対して実行する。
# 本番の DB を汚さないよう、テスト用の設定で別ポートに立てること(README 参照)。
ENGHI_TEST_URL ?= http://127.0.0.1:7799

# consult / markdown-mode が入っていればそれも読む。
# 入れずに走らせると該当テストが静かに飛び、「通った」ように見えるので注意。
ELPA_LOAD := --eval '(dolist (d (append (file-expand-wildcards "~/.emacs.d/elpa/*") \
                                        (file-expand-wildcards "~/.config/emacs/elpa/*"))) \
                       (when (file-directory-p d) (add-to-list (quote load-path) d)))'

SRC := enghi.el enghi-consult.el enghi-agenda.el

.PHONY: test compile clean

# 動いているサーバに対して ert を走らせる
test:
	ENGHI_TEST_URL=$(ENGHI_TEST_URL) $(EMACS) -Q --batch $(ELPA_LOAD) \
	  -L . -l enghi-tests.el -f ert-run-tests-batch-and-exit

# バイトコンパイルして警告を見る(.elc は残さない)
compile:
	$(EMACS) -Q --batch $(ELPA_LOAD) -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)
	@rm -f *.elc
	@echo "警告なし"

clean:
	rm -f *.elc
