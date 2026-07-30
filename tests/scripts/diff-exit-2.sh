#!/bin/sh
# Test fixture: a diff program that always fails, for exercising the
# retry-on-error path of the history sentinel.
echo "diff-exit-2 fixture failure" >&2
exit 2
