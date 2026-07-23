# frozen_string_literal: true

require "test_helper"

# Tripwire for the OWNED post-ship agent-docs sync (name-install-agent-docs-owner):
# `bin/release ship` auto-runs bin/install-agent-docs after the primaries are
# restored to the freshly shipped `main`, and the ship runbook NAMES the owner
# (Steffon) so installed-docs drift after an adapter/skill/SOP merge is somebody's
# problem, not nobody's. Drop the step or its documented owner and these fail.
class ShipDocsSyncDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read (mirrors review_lane_docs_test.rb): drop
  # * and ` and collapse whitespace so a line-wrapped phrase matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] the ship runbook documents the post-ship agent-docs sync and its owner" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/post-ship agent-docs sync/i, body,
      "the ship building block documents the owned bin/install-agent-docs run")
    assert_match(/post-ship agent-docs sync[^|]{0,900}owner: steffon/im, body,
      "the sync step names its owner (Steffon) in the ship runbook")
    assert_match(/non-fatal/i, body, "the sync is documented as non-fatal — it never aborts a completed ship")
  end

  test "[static] the production-deploy act (heartbeats) carries the docs-sync step" do
    body = norm("modules/heartbeats.md")
    assert_match(/post-ship agent-docs sync[^.]{0,300}install-agent-docs/im, body,
      "Act 1 (production-deploy) lists the docs-sync step")
    assert_match(/steffon owns this step/i, body, "the act names Steffon as the step's owner")
  end

  test "[static] the canonical production-deploy SOP (Avi) carries the docs-sync step" do
    body = norm("agents/steffon/sops/production-deploy.md")
    assert_match(/post-ship[^.]{0,200}install-agent-docs/im, body,
      "the SOP documents the post-ship installer run (relocated from the retired qa-release SKILL)")
    assert_match(/steffon owns the step/i, body, "the SOP names Steffon as the step's owner")
    assert_match(/non-fatal/i, body, "the SOP states the sync never aborts a completed ship")
  end

  test "[static] bin/release ship wires sync_agent_docs after restore_primaries" do
    src = File.read(Rails.root.join("bin", "release.rb"))
    restore_at = src.index("restore_primaries(app_groups)")
    sync_at    = src.index("sync_agent_docs\n")
    assert restore_at && sync_at, "ship must call both restore_primaries and sync_agent_docs"
    assert_operator restore_at, :<, sync_at,
      "the docs sync runs AFTER the primaries are restored to the shipped main"
  end
end
