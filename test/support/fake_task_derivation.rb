# frozen_string_literal: true

# A stand-in for Github::TaskDerivation, driven by plain hashes, so a model or
# selector test can say "GitHub places this PR on `release`" without a network.
#
#   rungs:    { "<pr url>" => "main" | "release" | "accepted" | nil | :unreadable }
#   branches: { ["<repo>", "<branch>"] => "<pr url>" }
#   authors:  { "<pr url>" => ["<soul>", ...] | :unreadable }
class FakeTaskDerivation
  attr_reader :calls

  def initialize(rungs: {}, branches: {}, authors: {})
    @rungs = rungs
    @branches = branches
    @authors = authors
    @calls = []
  end

  def merged_rung(pr_url)
    @calls << [:merged_rung, pr_url]
    answer(@rungs.fetch(pr_url, nil))
  end

  def pr_url_for_branch(repo, branch, exclude: [])
    @calls << [:pr_url_for_branch, repo, branch]
    url = answer(@branches[[repo, branch]])
    gone = Array(exclude).flat_map { |note| Github::TaskDerivation.pr_urls_in(note) }
    url && gone.include?(Github::TaskDerivation.normalize_url(url)) ? nil : url
  end

  def authors(pr_url)
    @calls << [:authors, pr_url]
    Array(answer(@authors.fetch(pr_url, [])))
  end

  private

  def answer(value)
    raise Github::TaskDerivation::Unreadable, "fake unreadable" if value == :unreadable

    value
  end
end
