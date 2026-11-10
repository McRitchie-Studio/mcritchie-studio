# frozen_string_literal: true

require "test_helper"
require_relative "../lib/release_cli_harness"

# [integration] prepare's detection read, run against this database (task
# release-prepare-night-lessons). The snippet is the real bin/release sweep_detect_ruby;
# only the transport is skipped. An `assembled` member of the active release that --task
# names comes back as a `refreeze` row, so the operator can re-freeze a release whose
# `release` branch moved without naming an unrelated still-`reviewed` task.
class ReleaseRefreezeDetectTest < ActiveSupport::TestCase
  class Cli < ReleaseCliHarness; end

  def detect(slugs)
    ruby = Cli.new("refreeze_detect").eval_helper(%(sweep_detect_ruby(#{slugs.inspect})))
    out, = capture_io { eval(ruby, TOPLEVEL_BINDING.dup, "bin/release detect") } # rubocop:disable Security/Eval
    JSON.parse(out.lines.last)
  end

  def assembled_member
    member = Task.create!(title: "assembled refreeze member task", stage: "reviewed",
                          metadata: { "devops" => { "shape" => "backend", "repositories" => [ "mcritchie-studio" ] } })
    rel = Release::Conductor.sweep!(member)
    Release::Conductor.qa_green!(rel)
    [member.reload, rel]
  end

  test "[integration] --task naming an assembled member of the active release detects it as a re-freeze row" do
    Release.delete_all
    member, rel = assembled_member
    assert_equal "assembled", member.stage
    assert_equal rel.slug, member.release_slug

    rows = detect([ member.slug ])["tasks"]

    assert_equal [ member.slug ], rows.map { |row| row["slug"] }
    assert_equal true, rows.first["refreeze"]
    assert_equal "assembled", rows.first["stage"]
  end

  test "[integration] without --task an assembled member is never swept again" do
    Release.delete_all
    member, = assembled_member

    rows = detect([])["tasks"]

    refute_includes rows.map { |row| row["slug"] }, member.slug, "a plain prepare sweeps candidates only"
  end

  test "[integration] an assembled task of no active release is a straggler, not a re-freeze" do
    Release.delete_all
    straggler = Task.create!(title: "assembled straggler leftover task", stage: "assembled",
                             merged: Task::MERGED_RELEASE,
                             metadata: { "devops" => { "repositories" => [ "mcritchie-studio" ] } })

    rows = detect([ straggler.slug ])["tasks"]

    assert_equal [ false ], rows.map { |row| row["refreeze"] }
  end
end
