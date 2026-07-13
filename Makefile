EMACS ?= emacs
TEST_FILES ?= tests/minuet-tests.el tests/minuet-diff-tests.el tests/minuet-duet-tests.el tests/minuet-duet-history-tests.el
EL_FILES ?= minuet.el minuet-diff.el minuet-duet.el minuet-duet-history.el
MINUET_TEST_EMACS_DIR ?= $(CURDIR)/.cache/emacs

.PHONY: test check compile benchmark clean-test-cache

test: check

check:
	MINUET_TEST_EMACS_DIR="$(MINUET_TEST_EMACS_DIR)" \
	$(EMACS) -Q --batch $(foreach file,$(TEST_FILES),-l $(file)) -f ert-run-tests-batch-and-exit

compile:
	MINUET_TEST_EMACS_DIR="$(MINUET_TEST_EMACS_DIR)" \
	$(EMACS) -Q --batch -l tests/test-helper.el -L . -f batch-byte-compile $(EL_FILES)

benchmark:
	MINUET_TEST_EMACS_DIR="$(MINUET_TEST_EMACS_DIR)" \
	$(EMACS) -Q --batch -l tests/test-helper.el -L . \
		-l benchmarks/minuet-duet-history-benchmarks.el \
		-f minuet-duet-history-benchmark-run

clean-test-cache:
	rm -rf "$(MINUET_TEST_EMACS_DIR)"
