# frozen_string_literal: true

require "test_helper"

class ReviewCommentTaxonomyDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] review comment taxonomy separates clarification from qa feedback" do
    body = norm("modules/review-comment-taxonomy.md")

    assert_match(/clarification[^.]{0,120}non-blocking/im, body)
    assert_match(/qa_feedback[^.]{0,120}blocking/im, body)
    assert_match(/handoff[^.]{0,140}addressed/im, body)
    assert_match(/PR comment/i, body)
  end

  test "[static] task-board docs point agents at the comment taxonomy" do
    body = norm("modules/devops-task-board.md")

    assert_match(/review-comment-taxonomy\.md/i, body)
    assert_match(/clarification/i, body)
  end
end
