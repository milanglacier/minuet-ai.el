EMACS ?= emacs
TEST_FILES ?= tests/minuet-diff-tests.el tests/minuet-duet-tests.el
EL_FILES ?= minuet.el minuet-diff.el minuet-duet.el

.PHONY: test check compile

test: check

check:
	$(EMACS) -Q --batch $(foreach file,$(TEST_FILES),-l $(file)) -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -l tests/test-helper.el -L . -f batch-byte-compile $(EL_FILES)
