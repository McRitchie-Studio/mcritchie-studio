# frozen_string_literal: true

require "test_helper"

# Tripwire for the docs that describe the reclaim gate's BOARD-STAGE channel
# (task sync-reclaim-docs-to-stage, 2026-09-20).
#
# `reclaim-gate-reads-board` added a sixth channel to `bin/agent-worktree`'s
# reclaim gate: it reads the bound task's board `stage` and frees a desk only at
# `shipped` or `archived`. Five doc sites kept describing the world before it —
# one of them `docs/agents/index.md`, which installs as
# `/Users/alex/projects/AGENTS.md` and is auto-loaded by every agent on this
# machine. A doc that misdescribes a gate which DESTROYS work is the failure
# mode this file exists to catch, so every assertion below is anchored to
# `bin/agent-worktree` itself rather than to a second copy of the claim: move
# the gate and these go red, instead of the prose quietly drifting again.
#
# Assertions are written `assert body.match?(...)` rather than `assert_match`
# on purpose — a failed `assert_match` prints the entire haystack, and the
# haystack here is a 1,000-line doc.
#
# NOTE FOR THE RUNNER, measured rather than assumed. A changed TEST file maps to
# itself, so `bin/fast-check` DOES run this lane whenever this file is in the diff
# — it ran here on the shipping commit (`mapped-tests: PASS`, 2026-09-20). What it
# cannot do is run it on the diff that matters: a prose-only edit to the docs below
# maps to no test at all, so the drift this guard exists to catch reaches the
# builder's cert unseen and is caught by CI's full suite instead. Run it by hand
# when you touch those docs:
#   bin/rails test test/docs/reclaim_stage_channel_docs_test.rb
class ReclaimStageChannelDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")
  GATE = Rails.root.join("bin", "agent-worktree")

  # Every doc that describes the reclaim gate's withholding rules. A claim about
  # WHEN a desk is taken belongs on this list; a passing mention does not.
  #
  # index.md left this list on 2026-09-24 (agents-map-two-hundred-lines): the map no
  # longer describes the reclaim gate, so keeping it here would pass on the bare
  # stage words in its pipeline section and prove nothing. modules/worktrees.md,
  # which the map links for desks, carries the rules and stays guarded.
  RECLAIM_DOCS = [
    "modules/worktrees.md",
    "modules/parallel-agent-devops.md",
    "agents/steffon/sops/clean-infra.md",
    "agents/steffon/sops/archive-shipped.md",
    "agents/xan/sops/clean-up.md"
  ].freeze

  # Markdown-emphasis-insensitive read (the house pattern, mirrors
  # ship_wait_docs_test.rb): drop * and ` and collapse whitespace, so a
  # line-wrapped phrase matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  def gate_source
    @gate_source ||= File.read(GATE)
  end

  # Live agent docs only. Audits and archives are frozen snapshots of what was
  # true when they were written, and correcting them would falsify the record.
  def live_docs
    Dir.glob(AGENTS.join("**", "*.md")).reject { |p| p.include?("/audits/") || p.include?("/archive/") }
  end

  test "[static] the free set the docs promise is the one the gate holds" do
    declared = gate_source[/^RECLAIMABLE_STAGES = %w\[([^\]]+)\]/, 1]
    assert declared, "bin/agent-worktree must declare RECLAIMABLE_STAGES for these docs to pin"
    assert_equal %w[shipped archived], declared.split,
      "the free set moved in the code; every doc below names it by hand and must move too"

    RECLAIM_DOCS.each do |rel|
      body = norm(rel)
      declared.split.each do |stage|
        assert body.match?(/\b#{stage}\b/),
          "#{rel} describes when the reclaim takes a desk, so it must name the terminal stage #{stage}"
      end
    end
  end

  test "[static] no doc states the stage channel fails OPEN on an unreadable board" do
    # The gate WITHHOLDS on :unreadable. worktrees.md stated the split backwards
    # — a one-word inversion of the whole doctrine, inside a paragraph that says
    # "it withholds" three times.
    reason = gate_source[/def stage_hold_reason.*?^end/m].to_s
    assert reason.match?(/when :unreadable\s+"/),
      "stage_hold_reason must still return a withhold reason for an unreadable board"

    live_docs.each do |path|
      body = File.read(path).gsub(/[*`]/, "").gsub(/\s+/, " ")
      refute body.match?(/failing open on an unreadable board/i),
        "#{path} states the fail-open/fail-closed split backwards — the gate fails CLOSED"
    end

    assert norm("modules/worktrees.md").match?(/failing closed on an unreadable board/i),
      "worktrees.md owns the doctrine paragraph and must state the posture the gate holds"
  end

  test "[static] no linger claim stops at the desk channel's idle window" do
    RECLAIM_DOCS.each do |rel|
      body = norm(rel)
      refute body.match?(/linger\w*[^.]{0,140}1h29m/i),
        "#{rel} says a desk lingers 1h29m; a BOUND desk now lingers until shipped/archived"
      refute body.match?(/1h29m[^.]{0,140}linger\w*/i),
        "#{rel} says a desk lingers 1h29m; a BOUND desk now lingers until shipped/archived"
    end
  end

  test "[static] no doc claims the reclaim can take a desk at reviewed" do
    body = norm("modules/devops-task-board.md")
    assert body.match?(/window closes at reviewed/i),
      "the approval-window paragraph is what this assertion guards"
    refute body.match?(/reviewed[^.]{0,200}cleanup --reclaim[^.]{0,160}from that moment/i),
      "at reviewed the stage channel WITHHOLDS the desk — the conclusion stands, the rationale does not"

    # EVERY reclaim doc, not just the one that happened to be wrong first.
    # Scoping this to devops-task-board.md left the SAME false rationale
    # standing in worktrees.md — the canonical file — where correcting only one
    # copy turned a uniformly-wrong pair into a live contradiction.
    #
    # The limit, stated: this refutes the phrasings we have SEEN ("this desk is
    # reclaimable", "becomes reclaimable"). It cannot refute a claim nobody has
    # written yet. The assertion below it is the one that generalises — the free
    # set itself is read off the gate.
    RECLAIM_DOCS.each do |rel|
      refute norm(rel).match?(/\breviewed\b[^.]{0,160}(?:is|becomes|are) reclaimable\b/i),
        "#{rel} says a desk is reclaimable at reviewed; RECLAIMABLE_STAGES is " \
        "#{gate_source[/^RECLAIMABLE_STAGES = %w\[([^\]]+)\]/, 1].inspect}, so stage_hold WITHHOLDS it there"
    end
  end

  test "[static] the blind-channel example in the rationale line is a reachable one" do
    # reclaim_evidence renders a rationale ONLY when nothing holds, and every
    # non-established stage status holds — so a blind STAGE channel can never
    # appear in a rationale. It surfaces as a withhold.
    assert gate_source.match?(/rationale: hold \? nil :/),
      "reclaim_evidence must still render a rationale only when no channel holds"

    live_docs.each do |path|
      refute File.read(path).match?(/board stage NOT ESTABLISHED/),
        "#{path} offers a rationale string the gate cannot print — a blind stage channel withholds"
    end

    assert norm("agents/steffon/sops/clean-infra.md").match?(/blind stage channel/i),
      "clean-infra must say what a blind stage channel actually does"
  end

  test "[static] the channel enumerations count what the gate chains" do
    chain = gate_source[/def reclaim_hold.*?^end/m].to_s
    channels = chain.scan(/\b(\w+_hold)\(/).flatten.uniq - ["reclaim_hold"]
    assert_equal 6, channels.size,
      "reclaim_hold chains #{channels.inspect}; the docs below say six"

    assert norm("modules/worktrees.md").match?(/Six independent channels/i),
      "worktrees.md states the count; it must match the chain"

    # The two prose enumerations that listed the channels one by one and skipped
    # the stage one. Each must name the pipeline-stage question.
    {
      "modules/worktrees.md" => /reclaimable\?[^)]*\bshipped\b/i,
      "modules/parallel-agent-devops.md" => /withheld_reason[^)]*\bshipped\b/i
    }.each do |rel, pattern|
      assert norm(rel).match?(pattern),
        "#{rel} enumerates the withhold channels and must include the board-stage one"
    end

    live_docs.each do |path|
      refute File.read(path).gsub(/[*`]/, "").gsub(/\s+/, " ").match?(/of the five channels/i),
        "#{path} still counts five reclaim channels; the chain has #{channels.size}"
    end

    # PIN THE DERIVED FACT, NOT A HAND COUNT. The previous version of this
    # assertion demanded the prose say "four of the six channels are structurally
    # dead" — a number nothing in the code expresses, and which was WRONG on three
    # of the four it named. The counting question is itself the error: `reclaim_hold`
    # is an `||` chain, so only the first channel that returns is ever asked.
    #
    # What IS derivable is the shape. `claim_hold` sits second and returns a hold
    # outright for a discovered repo, so the four after it never execute. Both
    # halves are read off the source here, and the doc must describe THAT rather
    # than a tally.
    claim_index = channels.index("claim_hold")
    assert_equal 1, claim_index,
      "claim_hold is no longer second in reclaim_hold (#{channels.inspect}); the short-circuit " \
      "the docs describe is what makes a discovered desk safe, so its position is load-bearing"

    # Sliced to the discovered_app? BRANCH, not the whole method. A looser regex
    # matched a `return` further down claim_hold and stayed green when the branch
    # was made to fall through — measured. The branch is what is being asserted,
    # so the branch is what has to be read.
    claim_body = gate_source[/^def claim_hold.*?^end/m].to_s
    branch = claim_body[/^  if discovered_app\?.*?^  end$/m].to_s

    assert branch.present?,
      "could not find the `if discovered_app?` branch in claim_hold — this assertion has gone " \
      "blind and would pass on any body at all"
    assert branch.match?(/^    return "/),
      "the discovered_app? branch of claim_hold no longer RETURNS — if it falls through, the " \
      "four channels after it do run, and every doc below describes the wrong mechanism"

    body = norm("modules/worktrees.md")
    assert body.match?(/short-circuit/i),
      "worktrees.md must name the SHORT-CIRCUIT — 'how many channels are dead' is the wrong " \
      "question for an || chain, and asking it is how the prose came to describe an unreached " \
      "channel as a blind one"
    assert body.match?(/never run at all|unreached/i),
      "worktrees.md must say the later channels do not RUN. A blind channel returns nil, and " \
      "nil FREES — so 'dead' describes the desk as unprotected at the moment it is protected"
  end
end
