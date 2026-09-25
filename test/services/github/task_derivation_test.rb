# frozen_string_literal: true

require "test_helper"

# Github::TaskDerivation against a scripted client: the three derived facts
# (merged rung, PR url, authors) and the one rule that makes them safe to fall
# back from — a failed read RAISES Unreadable, it never answers "not merged".
class Github::TaskDerivationTest < ActiveSupport::TestCase
  PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/42"
  NWO = "McRitchie-Studio/mcritchie-studio"
  SHA = "abc123"

  # Answers GETs from a { path => body | Exception } script and records each path.
  class ScriptedClient
    attr_reader :paths

    def initialize(script)
      @script = script
      @paths = []
    end

    def get(path, params: {}, headers: {})
      @paths << path
      value = @script.fetch(path) { raise Github::Client::HttpError, "GitHub API HTTP 404: unscripted #{path}" }
      raise value if value.is_a?(Exception)

      value
    end

    def paginate(path, params: {}, headers: {})
      Array(get(path, params: params, headers: headers))
    end
  end

  def pull(merged: true, sha: SHA, login: "mcritchie-agent[bot]")
    { "merged" => merged, "merge_commit_sha" => sha, "user" => { "login" => login } }
  end

  def compare(rung, status)
    ["/repos/#{NWO}/compare/#{rung}...#{SHA}", { "status" => status }]
  end

  def derivation(script)
    client = ScriptedClient.new(script)
    [Github::TaskDerivation.new(client: client), client]
  end

  test "[unit] merged rung is main when main contains the merge commit, and asks nothing lower" do
    subject, client = derivation({ "/repos/#{NWO}/pulls/42" => pull }.merge([compare("main", "behind")].to_h))
    assert_equal "main", subject.merged_rung(PR)
    refute client.paths.any? { |p| p.include?("compare/release") }, "a shipped PR costs one compare"
  end

  test "[unit] merged rung walks down to release, then accepted" do
    script = { "/repos/#{NWO}/pulls/42" => pull }.merge([compare("main", "ahead"), compare("release", "identical")].to_h)
    assert_equal "release", derivation(script).first.merged_rung(PR)

    script = { "/repos/#{NWO}/pulls/42" => pull }.merge(
      [compare("main", "ahead"), compare("release", "ahead"), compare("accepted", "behind")].to_h
    )
    assert_equal "accepted", derivation(script).first.merged_rung(PR)
  end

  test "[unit] an unmerged PR has no rung and asks no compare" do
    subject, client = derivation("/repos/#{NWO}/pulls/42" => pull(merged: false, sha: nil))
    assert_nil subject.merged_rung(PR)
    assert_equal ["/repos/#{NWO}/pulls/42"], client.paths
  end

  test "[unit] a missing branch (404) is not-contained, but a 500 is unreadable" do
    # main and release unscripted -> 404 -> not contained; accepted contains it.
    script = { "/repos/#{NWO}/pulls/42" => pull }.merge([compare("accepted", "behind")].to_h)
    assert_equal "accepted", derivation(script).first.merged_rung(PR)

    script = { "/repos/#{NWO}/pulls/42" => pull,
               "/repos/#{NWO}/compare/main...#{SHA}" => Github::Client::HttpError.new("GitHub API HTTP 500: boom") }
    assert_raises(Github::TaskDerivation::Unreadable) { derivation(script).first.merged_rung(PR) }
  end

  test "[unit] a failed PR read is unreadable, never nil" do
    script = { "/repos/#{NWO}/pulls/42" => Github::Client::HttpError.new("GitHub API HTTP 401: Bad credentials") }
    assert_raises(Github::TaskDerivation::Unreadable) { derivation(script).first.merged_rung(PR) }
    assert_raises(Github::TaskDerivation::Unreadable) { derivation({}).first.merged_rung("not a url") }
  end

  test "[unit] PR url for a branch prefers merged, then open, and skips abandoned PRs" do
    list = [
      { "number" => 9, "html_url" => "#{PR.sub('42', '9')}", "state" => "closed", "merged_at" => nil },
      { "number" => 10, "html_url" => "#{PR.sub('42', '10')}", "state" => "closed", "merged_at" => "2026-09-20T00:00:00Z" },
      { "number" => 11, "html_url" => "#{PR.sub('42', '11')}", "state" => "open", "merged_at" => nil }
    ]
    client = ScriptedClient.new("/repos/#{NWO}/pulls" => list)
    subject = Github::TaskDerivation.new(client: client)

    assert_equal PR.sub("42", "10"), subject.pr_url_for_branch("mcritchie-studio", "feat/x")
    assert_equal PR.sub("42", "11"),
                 subject.pr_url_for_branch("mcritchie-studio", "feat/x", exclude: ["abandoned #{PR.sub('42', '10')} (superseded)"])
    assert_nil subject.pr_url_for_branch("", "feat/x")
  end

  test "[unit] authors map soul emails and trailers, and ignore the operator and the bot" do
    commits = [
      { "commit" => { "author" => { "email" => "mack@mcritchie.studio" }, "committer" => { "email" => "noreply@github.com" },
                      "message" => "Build it\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" } },
      { "commit" => { "author" => { "email" => "amcritchie@gmail.com" }, "committer" => { "email" => "amcritchie@gmail.com" },
                      "message" => "zap\n\nCo-Authored-By: Steffon <steffon@mcritchie.studio>" } },
      { "commit" => { "author" => { "email" => "alex@mcritchie.studio" }, "committer" => {}, "message" => "docs" } },
      { "commit" => { "author" => { "email" => "310847602+mcritchie-agent[bot]@users.noreply.github.com" },
                      "committer" => {}, "message" => "Merge accepted" } },
      { "commit" => { "author" => { "email" => "stefon@mcritchie.studio" }, "committer" => {}, "message" => "typo soul" } }
    ]
    script = { "/repos/#{NWO}/pulls/42/commits" => commits, "/repos/#{NWO}/pulls/42" => pull(login: "carl") }

    assert_equal %w[mack steffon xan carl].sort, derivation(script).first.authors(PR).sort,
                 "alex resolves to xan; the operator, the bot and a non-roster local part name nobody"
  end
end
