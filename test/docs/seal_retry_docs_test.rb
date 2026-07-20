# frozen_string_literal: true

require "test_helper"

# REVIEW ROUND 2 (carl, request-changes): "missing ship docs". The seal's
# boot-window retry changes what a shipping operator SEES — a ship can now pause
# ~30s at step 5c, and a green seal can carry a "retried once" note. Undocumented,
# that reads as a hung ship or a suspicious seal. These tripwires keep the ship
# docs telling the truth about the retry (mirrors ship_docs_sync_docs_test.rb).
class SealRetryDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read: drop * and ` and collapse whitespace so a
  # line-wrapped phrase matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] the G4 gate doc documents the seal's one boot-window retry" do
    body = norm("modules/gates/g4-ship.md")
    assert_match(/retr(y|ies|ied) once/i, body, "the gate doc states the seal retries once")
    assert_match(/boot.window/i, body, "it names WHY — the dyno boot/restart window")
    assert_match(/retr[^.]{0,200}(30s|30 seconds)/i, body, "it states the ~30s wait an operator will see")
  end

  test "[static] the production-deploy SOP tells the operator what the retry looks like" do
    body = norm("agents/avi/sops/production-deploy.md")
    assert_match(/boot.window/i, body, "the SOP names the boot-window retry at the seal step")
    assert_match(/retr[^.]{0,300}(30s|30 seconds)/i, body,
      "the SOP warns the ship can pause ~30s at the seal — not a hang")
    assert_match(/retried once/i, body,
      "the SOP explains a green seal may carry the retry note")
  end

  test "[static] the docs state a red seal means the failure PERSISTED through the retry" do
    sop  = norm("agents/avi/sops/production-deploy.md")
    gate = norm("modules/gates/g4-ship.md")
    assert_match(/persist/i, sop + gate,
      "a red seal is now a CONFIRMED failure (it survived the retry) — the docs must say so")
  end

  test "[static] the docs keep the seal's unchanged contract: non-blocking, never auto-rollback" do
    body = norm("modules/gates/g4-ship.md")
    assert_match(/never (aborts|flips)/i, body, "the retry did not make the seal a blocker")
  end
end
