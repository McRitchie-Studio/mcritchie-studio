require "test_helper"

class Github::CommitClassifierTest < ActiveSupport::TestCase
  test "detects merge commits from parent count" do
    payload = {
      "parents" => [{"sha" => "a"}, {"sha" => "b"}],
      "commit" => {"message" => "Feature work"}
    }

    assert Github::CommitClassifier.merge?(payload)
  end

  test "detects merge commits from message prefix" do
    payload = {
      "parents" => [{"sha" => "a"}],
      "commit" => {"message" => "Merge pull request #1"}
    }

    assert Github::CommitClassifier.merge?(payload)
  end

  test "detects obvious bot commits" do
    payload = {
      "author" => {"login" => "dependabot[bot]"},
      "committer" => {"login" => "github-actions[bot]"},
      "commit" => {"message" => "Bump rack"}
    }

    assert Github::CommitClassifier.bot?(payload)
  end

  test "does not flag normal builder commits as bots" do
    payload = {
      "author" => {"login" => "human-builder"},
      "commit" => {"message" => "Improve adapter boundaries"}
    }

    assert_not Github::CommitClassifier.bot?(payload)
  end
end
