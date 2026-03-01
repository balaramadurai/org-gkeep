EMACS ?= emacs

# Load path for dependencies. Override for CI or non-straight setups.
# Example: make test DEPS_DIRS="-L /path/to/request"
STRAIGHT_DIR ?= $(HOME)/.config/emacs/straight/repos
DEPS_DIRS ?= -L $(STRAIGHT_DIR)/emacs-request

.PHONY: test lint clean

test:
	$(EMACS) -Q -batch -L . $(DEPS_DIRS) \
	  -l test/org-gkeep-test.el \
	  -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q -batch -L . \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  --eval "(unless (package-installed-p 'request) (package-install 'request))" \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit org-gkeep.el

clean:
	rm -f *.elc test/*.elc
