#!/usr/bin/env bash
# owner/repository from any GitHub URL: an https or ssh remote with or without
# .git, or a pull request URL. Prints nothing when the URL is not GitHub.
#
# A standalone executable rather than a sourced library function: the two
# consumers (fm-teardown.sh and fm-bearings-snapshot.sh) share only this one
# parse, and invoking it keeps the read-only snapshot tool decoupled from the
# rest of the PR library. fm_pr_url_parse in bin/fm-pr-lib.sh remains the
# validating parser for PR URLs.
printf '%s' "${1-}" |
  sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\).*#\1#p' | sed 's#\.git$##'
