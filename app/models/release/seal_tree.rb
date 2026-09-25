class Release
  # WHERE the post-ship smoke seal runs its specs, and whether it can run them at
  # all (bin/release step 5c, production_smoke_seal; also `bin/release reseal`).
  #
  # WHY IT EXISTS (rel-20260925-3b1f5c): the seal ran bin/prod-smoke from the hub
  # PRIMARY checkout. The primary still held the PRE-ship tree (step 7 restores it
  # only after the seal), so the seal smoked the OLD e2e specs against the NEW
  # prod — they looked for a page the ship had just renamed — and recorded a false
  # red. A manual re-run from the shipped tree passed 5/5.
  #
  # THE RULE: the seal runs the specs of the tree that SHIPPED, which is the ship
  # workspace (Release::GateWorkspace role "ship", <hub>/.worktrees/_ship) pinned
  # at the frozen ship SHA. It NEVER falls back to the primary: a primary may hold
  # a live session's work, and its tree is whatever it happens to be. When the
  # shipped specs cannot be run, the seal records UNSEALED — not red. A red seal
  # tells the operator that prod is broken; "we could not look" is a different
  # fact, and conflating the two is how a false red reaches a rollback prompt.
  #
  # Pure + Rails-FREE (like SealRun / SealRetry / SmokeSeal) so bin/release can
  # `require_relative` it; bin/release gathers the facts (the pin, HEAD) and hands
  # them here.
  module SealTree
    module_function

    # The verdict status the seal returns (and the G4 gate records as
    # metadata.seal) when the shipped specs could not run. Deliberately NOT a
    # Release::SmokeSeal status: an unsealed release stores no seal at all, which
    # the board, the notes, and finalize already read as "unsealed".
    UNSEALED = "unsealed".freeze

    # The script the seal runs, and the runner it needs, relative to the tree.
    SCRIPT     = File.join("bin", "prod-smoke").freeze
    PLAYWRIGHT = File.join("node_modules", ".bin", "playwright").freeze

    # `root` is the tree to run the seal from; `reason` is nil when it can run,
    # else why it cannot (the unsealed summary carries it).
    Verdict = Struct.new(:root, :reason, keyword_init: true) do
      def runnable? = reason.nil?
    end

    # PURE (plus File stat reads). Can the seal run the shipped specs from
    # `workspace`? `head_sha` is the workspace's HEAD as git reports it;
    # `frozen_sha` is what shipped. Every refusal names what failed, so the
    # operator's remedy is in the line.
    def resolve(workspace:, frozen_sha:, head_sha:)
      frozen = frozen_sha.to_s.strip
      head   = head_sha.to_s.strip
      root   = workspace.to_s.strip

      return refuse("no frozen ship SHA was recorded for the hub") if frozen.empty?
      return refuse("the ship workspace is missing") if root.empty? || !File.directory?(root)
      unless !head.empty? && same_commit?(head, frozen)
        return refuse("the ship workspace is at #{short(head)}, not the frozen ship SHA #{short(frozen)}")
      end
      return refuse("the shipped tree has no #{SCRIPT}") unless File.executable?(File.join(root, SCRIPT))
      return refuse("playwright is not installed in the ship workspace") unless File.executable?(File.join(root, PLAYWRIGHT))

      Verdict.new(root: root, reason: nil)
    end

    # A caller that could not even gather the facts (the pin aborted, git raised)
    # still gets a Verdict, never an exception: the seal is non-blocking.
    def refuse(reason)
      Verdict.new(root: nil, reason: reason.to_s)
    end

    # The one-line summary the ship log, the release event, and the G4 gate read.
    def summary(reason)
      "#{UNSEALED}: could not run the shipped specs — #{reason}"
    end

    # A full SHA and an abbreviation of it name the same commit; two different
    # full SHAs do not. Case-insensitive, and a blank never matches.
    def same_commit?(a, b)
      a = a.to_s.strip.downcase
      b = b.to_s.strip.downcase
      return false if a.empty? || b.empty?

      a.start_with?(b) || b.start_with?(a)
    end

    def short(sha)
      s = sha.to_s.strip
      s.empty? ? "(unknown)" : s[0, 7]
    end
  end
end
