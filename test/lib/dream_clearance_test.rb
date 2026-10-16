# frozen_string_literal: true

# [unit] DreamClearance — the rule for Alex's quoted words on a chat ruling, shared
# by bin/dream and DreamRuling (docs/agents/modules/dream.md, Act 3, "In chat").
#   ruby -Itest test/lib/dream_clearance_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/dream_clearance"

class DreamClearanceTest < Minitest::Test
  def problem(words, slug: "pass-the-author") = DreamClearance.problem(words, slug: slug)

  def test_unit_his_words_pass
    assert_nil problem("Approve the begin dream, it is right")
    assert_nil problem("yes drop that one")
  end

  def test_unit_an_empty_clearance_is_refused
    [ nil, "", "   " ].each { |words| assert_includes problem(words), "none was given" }
  end

  def test_unit_the_slug_alone_is_refused_in_any_dress
    [ "pass-the-author", "`pass-the-author`", "sops/building-sop/pass-the-author", "\"Pass-The-Author\"" ].each do |words|
      assert_includes problem(words), "only the slug", words
    end
  end

  def test_unit_fewer_than_three_words_is_refused
    [ "ok", "approve it", "sure thing" ].each do |words|
      assert_includes problem(words), "shorter than 3 words", words
    end
  end

  def test_unit_the_card_grammar_stands_as_his_whole_answer
    [ "yes", "Yes.", "YES!", "1 ✓", "1 ✓ 2 ✗", "1 ✓, 2 ✗, 3 ✎ shorten the why", "2 ✎ say 'desk' not 'worktree'" ].each do |words|
      assert_nil problem(words), words
    end
  end

  def test_unit_grammar_lookalikes_are_not_grammar
    [ "yes?", "1", "✓", "1 ✎" ].each { |words| refute_nil problem(words), words }
  end
end
