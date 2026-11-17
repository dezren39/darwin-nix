#!/usr/bin/env bash
# failing-jobs.sh <repo> <run-id>
#
# Prints the sorted, comma-joined names of a workflow run's failed or
# timed-out jobs, across ALL pages of the jobs API (empty output when
# none). Consumed by .github/workflows/main-broken-watcher.yml, whose
# issue title and Breakage-ID are built from this list.
#
# #1887: the watcher used to read only the first jobs page (the API
# default page size is 30) and substitute a "(no failed jobs reported)"
# sentinel, so real matrix failures on later pages were lost and
# distinct breakages collapsed onto one Breakage-ID. --paginate (with
# per_page=100) makes truncation impossible rather than moving the cap.
set -euo pipefail

repo="${1:?usage: failing-jobs.sh <repo> <run-id>}"
run_id="${2:?usage: failing-jobs.sh <repo> <run-id>}"

gh api --paginate "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
  --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .name' \
  | LC_ALL=C sort | paste -sd, -
