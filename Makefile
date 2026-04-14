EMACS ?= emacs
TEST_FILE ?= tests/minuet-duet-tests.el

.PHONY: test check

test: check

check:
	$(EMACS) -Q --batch -l $(TEST_FILE) -f ert-run-tests-batch-and-exit
