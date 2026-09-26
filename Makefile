# emacs may not be in PATH (emacs-plus is placed in Cellar).
# If not found, look for the latest Homebrew version. Can be overridden with EMACS=....
EMACS ?= $(shell command -v emacs 2>/dev/null || \
           ls -1d /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort -V | tail -1 || \
           echo emacs)

# Run tests against a **running enghi server**.
# Start on a separate port with test settings to avoid dirtying the production DB (see README).
ENGHI_TEST_URL ?= http://127.0.0.1:7799

# Also load consult / markdown-mode if installed.
# Note: running without them quietly skips tests, making them look like they passed.
ELPA_LOAD := --eval '(dolist (d (append (file-expand-wildcards "~/.emacs.d/elpa/*") \
                                        (file-expand-wildcards "~/.config/emacs/elpa/*"))) \
                       (when (file-directory-p d) (add-to-list (quote load-path) d)))'

SRC := enghi.el enghi-consult.el enghi-dashboard.el

.PHONY: test compile clean

# Run ert against the running server
test:
	ENGHI_TEST_URL=$(ENGHI_TEST_URL) $(EMACS) -Q --batch $(ELPA_LOAD) \
	  -L . -l enghi-tests.el -f ert-run-tests-batch-and-exit

# Byte-compile and check warnings (do not keep .elc)
compile:
	$(EMACS) -Q --batch $(ELPA_LOAD) -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)
	@rm -f *.elc
	@echo "No warnings"

clean:
	rm -f *.elc
