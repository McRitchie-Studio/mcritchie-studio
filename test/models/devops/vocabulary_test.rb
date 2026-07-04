# frozen_string_literal: true

require "test_helper"

# Devops::Vocabulary reads config/devops_vocabulary.yml — the SINGLE SOURCE OF
# TRUTH the /stages/sop infographic + ApplicationHelper render from. These guard
# the shape the views rely on (four lanes, symbol step types, one pulse per lane).
class Devops::VocabularyTest < ActiveSupport::TestCase
  test "[unit] loads the four accountability lanes in owner order" do
    lanes = Devops::Vocabulary.lanes
    assert_equal 4, lanes.size
    assert_equal ["Builder", "Primary Reviewer", "Steffon", "Avi"], lanes.map { |lane| lane[:owner] }
  end

  test "[unit] every step's :type is a Symbol (view compares step[:type] == :pulse)" do
    Devops::Vocabulary.lanes.each do |lane|
      lane[:steps].each do |step|
        assert_kind_of Symbol, step[:type], "#{lane[:owner]} step #{step[:label].inspect} type must be a Symbol"
      end
    end
  end

  test "[unit] node_type resolves a known type by Symbol or String" do
    assert_equal "Pulse", Devops::Vocabulary.node_type(:pulse)[:kind]
    assert_equal "Pulse", Devops::Vocabulary.node_type("pulse")[:kind]
  end

  test "[unit] node_type falls back to :stage for an unknown type" do
    assert_equal Devops::Vocabulary.node_types[:stage], Devops::Vocabulary.node_type(:bogus)
  end

  test "[unit] exactly one pulse marks each lane's live intent" do
    Devops::Vocabulary.lanes.each do |lane|
      pulses = lane[:steps].count { |step| step[:type] == :pulse }
      assert_equal 1, pulses, "lane #{lane[:owner]} must have exactly one pulse (the live intent marker)"
    end
  end

  test "[unit] owner_definition is present" do
    assert Devops::Vocabulary.owner_definition.present?
  end

  test "[unit] reviewer_roles carries the primary + light roles (the single source)" do
    roles = Devops::Vocabulary.reviewer_roles
    assert_equal %i[primary light], roles.keys, "primary is the deep seat, light the second pass"
    assert roles[:primary].present?, "the primary role has a description"
    assert roles[:light].present?, "the light role has a description"
  end

  test "[unit] ReviewerSelector sources its role names from the vocabulary" do
    assert_equal "primary", ReviewerSelector.primary_role, "the deep seat reads from reviewer_roles"
    assert_equal "light", ReviewerSelector.light_role, "the light seat reads from reviewer_roles"
    assert_equal Devops::Vocabulary.reviewer_roles.keys.map(&:to_s),
                 [ReviewerSelector.primary_role, ReviewerSelector.light_role],
                 "the selector role names ARE the vocabulary's reviewer_roles, in order"
  end

  test "[unit] no step diverges — Release Branch is Steffon's sweep (2026-07-03), review is review-only" do
    diverging = Devops::Vocabulary.lanes.flat_map { |lane| lane[:steps] }.select { |step| step[:diverges].present? }
    assert_empty diverging,
      "no step should carry a :diverges note — the implemented model now matches the SOP " \
      "(#{diverging.map { |step| step[:label] }.inspect} still diverge)"

    # The Release Branch (merge) step lives in STEFFON'S Assemble lane now — his
    # self-healing sweep owns the merge; the Review lane stops at Reviewed.
    review   = Devops::Vocabulary.lanes.find { |lane| lane[:lane] == "Review" }
    assemble = Devops::Vocabulary.lanes.find { |lane| lane[:lane] == "Assemble" }

    assert_nil review[:steps].find { |step| step[:label] == "Release Branch" },
      "the Review lane must NOT carry the merge — review is review-only (Steffon sweeps)"
    reviewed = review[:steps].find { |step| step[:stage] == "reviewed" }
    assert_match(/review-only/i, reviewed[:expectation], "the Reviewed close names the review-only contract")

    release_branch = assemble[:steps].find { |step| step[:label] == "Release Branch" }
    assert_not_nil release_branch, "the Assemble lane carries the Release Branch sweep step"
    assert_nil release_branch[:diverges]
    assert_match(/sweep/i, release_branch[:expectation], "the merge is the self-healing sweep's")
    assert_match(/merged: release/i, release_branch[:expectation], "the sweep stamps the crash-recovery git-location")

    # Assemble's Main Branch stays the reconciled merge-forward guard.
    main_branch = assemble[:steps].find { |step| step[:label] == "Main Branch" }
    assert_not_nil main_branch, "the Assemble lane's Main Branch step should still exist"
    assert_nil main_branch[:diverges],
      "Main Branch is the merge-forward guard now, not a divergence — its :diverges note must be gone"
    assert_match(/merge-forward guard/i, main_branch[:expectation])
  end
end
