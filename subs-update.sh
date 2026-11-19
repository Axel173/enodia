#!/bin/sh
# Stable entry point for scheduled subscription updates and existing callers.
exec sh "$(dirname "$0")/subs-import.sh" "$@"
