#!/bin/sh
# Test fixture: a diff program that takes a while to finish, for
# exercising the bounded wait in `minuet-duet-history-flush'.
sleep 1
exec diff "$@"
