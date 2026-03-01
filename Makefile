EMACS ?= emacs

.PHONY: test lint clean setup

test:
	$(EMACS) -Q -batch -L . \
	  -l test/org-gkeep-test.el \
	  -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q -batch -L . \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit org-gkeep.el

setup:
	pip install gkeepapi

clean:
	rm -f *.elc test/*.elc
