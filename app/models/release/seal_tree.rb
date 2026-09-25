require "digest"

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
    
    # STALE DEPS ARE A FALSE RED (review of PR #1605). node_modules is gitignored,
    # so the workspace's `git clean -fd` keeps it across ships — which is the point
    # (warm), and the trap: a ship that bumps @playwright/test would run the shipped
    # specs on the OLD runner and seal red on a healthy prod. So the seal stamps the
    # sha256 of the package-lock.json it installed from, and re-runs `npm ci` when
    # the shipped lockfile no longer matches the stamp.
    LOCKFILE   = "package-lock.json".freeze
    DEPS_STAMP = File.join("node_modules", ".seal-package-lock.sha256").freeze
    
    # `npm ci` runs AFTER prod deployed, holding the ship-workspace lock that
    # `prepare` also waits on — so a hung install must not stall the ship. Bounded;
    # a timeout records unsealed. The env override exists for tests.
    NPM_CI_TIMEOUT_SECONDS = 600
    NPM_CI_TIMEOUT_ENV = "SEAL_NPM_CI_TIMEOUT_SECONDS".freeze

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
      return refuse("the ship workspace's node deps do not match the shipped #{LOCKFILE}") unless deps_current?(root)

      Verdict.new(root: root, reason: nil)
    end

    # The seconds `npm ci` may run before the seal gives up and records unsealed.
    def npm_ci_timeout
      override = ENV[NPM_CI_TIMEOUT_ENV].to_s.strip
      override.empty? ? NPM_CI_TIMEOUT_SECONDS : override.to_f
    end

    # sha256 of the tree's package-lock.json, or nil when it has none.
    def lock_digest(root)
      file = File.join(root.to_s, LOCKFILE)
      File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil
    end

    # Are the workspace's installed deps the ones the shipped lockfile names? True
    # only when playwright is installed AND the stamp matches the lockfile's hash.
    # No lockfile, no stamp, or a different stamp → not current (reinstall).
    def deps_current?(root)
      return false unless File.executable?(File.join(root.to_s, PLAYWRIGHT))

      digest = lock_digest(root)
      stamp  = File.join(root.to_s, DEPS_STAMP)
      !digest.nil? && File.file?(stamp) && File.read(stamp).strip == digest
    end

    # Record the lockfile a successful `npm ci` installed from.
    def stamp_deps!(root)
      digest = lock_digest(root)
      return unless digest

      File.write(File.join(root.to_s, DEPS_STAMP), "#{digest}\n")
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

    # --- reseal (bin/release reseal <release>) --------------------------------
    # `group` is the hub's repo_plan group to seal; `frozen_sha` is the hub SHA
    # that shipped; `note` rides the recorded summary; `refusal` is why the
    # release cannot be re-sealed (nil when it can).
    ResealPlan = Struct.new(:group, :frozen_sha, :note, :refusal, keyword_init: true)

    # PURE. Can this release be re-sealed, and from which SHA? Only a SHIPPED
    # release: one still in flight is sealed by its own ship or by finalize. The
    # SHA is the QA-frozen one the ship deployed (qa_shas), else the recorded
    # deployed_sha — never origin/release, which has moved on since.
    def reseal_plan(state:, repos:, qa_shas:, deployed_sha:, app:, superseded_by: nil)
      unless state.to_s == "shipped"
        return ResealPlan.new(refusal: "it is '#{state}', not shipped — a release in flight is sealed by " \
                                       "`bin/release ship` or `bin/release finalize`")
      end

      group = Array(repos).find { |g| g.is_a?(Hash) && g["repo"] == app && g["kind"].to_s == "app" }
      return ResealPlan.new(refusal: "#{app} was not deployed in it, so there is nothing to seal") unless group

      shas   = qa_shas.is_a?(Hash) ? qa_shas : {}
      frozen = shas[app].to_s.strip
      frozen = deployed_sha.to_s.strip if frozen.empty?
      return ResealPlan.new(refusal: "no frozen #{app} SHA is recorded on it (qa_shas or deployed_sha)") if frozen.empty?

      later = superseded_by.to_s.strip
      note  = "re-sealed from the shipped tree"
      note += "; prod has since moved to #{later}" unless later.empty?
      ResealPlan.new(group: group, frozen_sha: frozen, note: note, refusal: nil)
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
