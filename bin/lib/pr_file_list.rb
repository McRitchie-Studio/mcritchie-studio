# frozen_string_literal: true

# PrFileList — the one way a PR's changed files are read from GitHub, shared by
# bin/dor-check (the docs and test-only claims) and bin/merge-permit (who may merge).
#
# The REST files endpoint, not `gh pr view --json files`: that surface gives a
# rename's destination alone, so a script renamed into a .md would read as prose.
# REST carries `status` and `previous_filename`, so BOTH sides of a rename are
# listed. A renamed entry with no previous_filename gets a sentinel with no prose
# extension, which classifies as behavior: fail closed by construction.
module PrFileList
  RENAME_SENTINEL = "unknown-rename-source"
  JQ = '.[] | .filename, (if .status == "renamed" then (.previous_filename // "' \
       "#{RENAME_SENTINEL}" \
       '") else empty end)'
  PR_URL = %r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  module_function

  # [owner, repo, number], or nil when the url is not a GitHub pull request.
  def parse_url(url)
    url.to_s.strip.match(PR_URL)&.captures
  end

  # The `gh` argument vector for the read.
  def gh_args(owner, repo, number)
    ["api", "--paginate", "repos/#{owner}/#{repo}/pulls/#{number}/files", "--jq", JQ]
  end

  # The paths in a successful read's output; empty when it listed nothing.
  def parse(raw)
    raw.to_s.split("\n").map(&:strip).reject(&:empty?)
  end
end
