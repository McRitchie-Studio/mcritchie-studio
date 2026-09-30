# frozen_string_literal: true

require "test_helper"

# [docs] A THROWAWAY WORKTREE IS NEVER CUT INSIDE THE MANAGED ROOT
# (/tasks/reclaim-after-archive-window).
#
#   bin/rails test test/docs/throwaway_worktrees_outside_managed_root_docs_test.rb
#
# THE DEFECT. The review recipes (the mutation pass in worktrees.md, the zap protocol, Avi's
# arbitration) told a reviewer to cut a detached throwaway at `<repo>/.worktrees/<name>`.
# DeskRoot classifies anything directly under `.worktrees/` as a MANAGED desk, so the board
# opened a desk-ledger episode for it, and the reviewer's plain `git worktree remove` left
# that episode open as a `vanished` ghost: two of the six ghosts on 2026-09-29 were reviewer
# mutation checkouts. The recipes now cut throwaways in the session scratchpad.
#
# WHAT THIS PINS. Every fenced shell block under docs/agents (history and audits aside) that
# runs `git worktree add --detach` — a throwaway, never a desk; a desk is a named branch cut
# by bin/agent-worktree — must not target a path inside a managed root, checked with
# DeskRoot.managed_path? itself so the doc rule and the ledger rule cannot drift. A `$VAR`
# target is resolved through the block's own `VAR=...` assignments. `../<name>` counts as
# managed: run from a desk, it lands beside that desk inside `.worktrees/`.
class ThrowawayWorktreesOutsideManagedRootDocsTest < ActiveSupport::TestCase
  DOCS_ROOT = Rails.root.join("docs/agents")
  SKIPPED = %r{/docs/agents/(archive|audits|maintenance)/}

  # Walked line by line: a regex scan pairs one block's CLOSING fence with the next one's
  # opening and reads the prose between as code.
  def fenced_blocks(text)
    blocks = []
    current = nil
    text.each_line do |line|
      if line.strip.start_with?("```")
        current ? (blocks << current.join) : nil
        current = current ? nil : []
      elsif current
        current << line
      end
    end
    blocks
  end

  # The throwaway targets in one block, each already expanded through the block's assignments.
  def detached_targets(block)
    vars = {}
    block.each_line do |line|
      line.sub(/\s+#.*$/, "").split(/;\s+/).each do |segment|
        next unless (m = segment.strip.match(/\A([A-Z_]+)=(.+)\z/))

        vars[m[1]] = m[2].delete('"')
      end
    end
    block.each_line.filter_map do |line|
      next unless line.match?(/\bworktree add\b/) && line.include?("--detach")

      args = line.split("worktree add", 2).last.split(/\s+/).reject(&:empty?)
      target = args.reject { |arg| arg.start_with?("-") }.first.to_s.delete('"')
      target.gsub(/\$\{?([A-Z_]+)\}?/) { vars.fetch(Regexp.last_match(1), "$#{Regexp.last_match(1)}") }
    end
  end

  def managed?(target)
    target.start_with?("../") || DeskRoot.managed_path?(target)
  end

  def offenders
    Dir.glob(DOCS_ROOT.join("**/*.md")).reject { |path| path.match?(SKIPPED) }.flat_map do |path|
      fenced_blocks(File.read(path)).flat_map do |block|
        detached_targets(block).select { |target| managed?(target) }
                               .map { |target| "#{path.delete_prefix("#{Rails.root}/")}: #{target}" }
      end
    end
  end

  test "no doc cuts a detached throwaway worktree inside a managed root" do
    found = offenders

    assert found.empty?,
           "these recipes cut a throwaway worktree where DeskRoot calls it a MANAGED desk, so a " \
           "plain `git worktree remove` leaves a vanished ghost on the Desks panel. Cut it in the " \
           "session scratchpad (`$(mktemp -d)/<name>`) instead:\n  #{found.join("\n  ")}"
  end

  test "[unit] the resolver sees a managed target through a variable and a sibling path" do
    block = %(REPO=/x/app; MUT="$REPO/.worktrees/mut-1"\ngit worktree add "$MUT" --detach HEAD\n) +
            %(git worktree add ../unzap-1 --detach origin/accepted\n) +
            %(ZAP="$(mktemp -d)/zap-1"\ngit worktree add "$ZAP" --detach HEAD\n)
    targets = detached_targets(block)

    assert_equal 3, targets.size
    assert_equal [true, true, false], targets.map { |target| managed?(target) },
                 "the variable-held .worktrees path and the sibling path are managed; the scratchpad is not"
  end

  test "[unit] the recipes that motivated this still cut a throwaway, so the guard is reading them" do
    %w[modules/worktrees.md modules/zap-protocol.md agents/avi/sops/arbitrate-block.md].each do |doc|
      targets = fenced_blocks(File.read(DOCS_ROOT.join(doc))).flat_map { |block| detached_targets(block) }

      refute_empty targets, "#{doc} no longer has a detached worktree recipe this guard can see — " \
                            "if the recipe moved, point this test at its new home"
    end
  end
end
