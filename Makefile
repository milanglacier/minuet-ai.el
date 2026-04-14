EMACS ?= emacs
TEST_FILES ?= tests/minuet-diff-tests.el tests/minuet-duet-tests.el

.PHONY: test check

test: check

check:
	$(EMACS) -Q --batch $(foreach file,$(TEST_FILES),-l $(file)) -f ert-run-tests-batch-and-exit
