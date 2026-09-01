# frozen_string_literal: true

require_relative "full_suite_gate"

# LintWaiverGuard — keeps a DECLARED lint waiver honest against the tree it waives.
#
# THE TWO WAYS A LINT LANE CAN BE MISSING, and why they must stay distinguishable:
#
#   ABSENT  the repo ships no rubocop at all and never intended to. solana-studio
#           and studio-engine are the cases: no .rubocop.yml, no bin/rubocop, no
#           rubocop in the Gemfile or the gemspec. Their static gate is `ruby -c`
#           inside bin/release-check. There is no lint lane to fail here, so
#           demanding one means the cert can NEVER go green — which is what
#           `lint_lane: none` in config/release_repos.yml exists to say.
#
#   BROKEN  the repo DOES lint, and today the command is missing, unbootable, or
#           mis-installed. That is a red lane. Waiving it would silently stop
#           linting a repo that asked to be linted — a far worse defect than the
#           false red it would cure.
#
# TWO RULES, TOGETHER, MAKE THEM STRUCTURALLY DIFFERENT. Neither alone is enough:
#
#   1. NEVER INFERRED (FullSuiteGate#lint_waived?, unchanged and untouched by this
#      file). A missing rubocop binary waives NOTHING. Only a reviewable line in
#      config/release_repos.yml waives, so BROKEN can never be read as ABSENT —
#      a repo with no declaration whose rubocop cannot launch stays RED.
#
#   2. ALWAYS AUDITED (this file). A declaration is a claim about the tree, and a
#      claim that stops being true must stop being honoured. If a waived repo is
#      found to carry a lint toolchain, the cert REFUSES and names the registry
#      line to delete — so ABSENT can never quietly outlive the fact. Without this,
#      a repo could declare the waiver, later GAIN rubocop, and go on certifying
#      green while nothing linted it, indistinguishable from a genuinely
#      toolchain-less repo.
#
# THE DIRECTION IS THE WHOLE DESIGN: this guard may only REVOKE a waiver, never
# GRANT one. It returns a refusal string or nil; it has no "waive this" return
# value and no caller can read one out of it. That is why it lives in its own file
# rather than inside FullSuiteGate — the module that DECIDES the waiver must stay
# free of any environment read, and cert_lint_lane_waiver_test.rb asserts exactly
# that about full_suite_gate.rb's source. Composition keeps both properties
# checkable instead of trusting one file to hold two opposite habits.
#
# IT READS THE TREE, NEVER THE HOST. Every marker below is a committed file in the
# repo being certified. `which rubocop`, a bundle probe, or a global install are
# deliberately not consulted: those describe the MACHINE, and a waiver that moved
# with the machine would be the inference rule 1 forbids, arriving by the back door.
module LintWaiverGuard
  # WHAT COUNTS AS "THIS REPO LINTS", and the calibration behind each one. Every
  # marker is a DELIBERATE act by a human editing this repo — you do not acquire
  # a .rubocop.yml or a bin/rubocop by accident.
  #
  # Gemfile.lock is deliberately NOT a marker. rubocop can land in a lock file as
  # somebody else's transitive dependency, with nothing in the repo asking to be
  # linted; treating that as intent would refuse a waiver the repo is entitled to.
  # The lock records what RESOLVED, the Gemfile and gemspec record what was ASKED
  # FOR, and intent is the question here.
  CONFIG_FILES = [".rubocop.yml", ".rubocop.yaml"].freeze
  BINSTUB = "bin/rubocop"
  # Anchored at the start of a line so a MENTION cannot pass for a declaration:
  # a commented-out `# gem "rubocop"` and a sentence of prose naming rubocop both
  # fail to match, while the real dependency line matches.
  GEMFILE_RE = /^\s*gem\s+["']rubocop(?:-[\w.-]+)?["']/
  GEMSPEC_RE = /^\s*\S+\.add_(?:development_|runtime_)?dependency\s*[(\s]\s*["']rubocop(?:-[\w.-]+)?["']/

  module_function

  # The refusal message when `repo` declares `lint_lane: none` but the tree at
  # `root` carries a lint toolchain — else nil. nil is also the answer for every
  # repo that declares NO waiver, whatever its tree holds: this guard has no
  # opinion about an unwaived repo, because granting is not a thing it does.
  def refusal(repo:, root:)
    return nil unless FullSuiteGate.lint_waived?(repo)

    found = markers(root)
    return nil if found.empty?

    "#{repo} declares `lint_lane: none` in config/release_repos.yml, but this tree carries a lint " \
      "toolchain: #{found.join(', ')}. The waiver is a claim that this repo has no lint lane, and it is " \
      "no longer true — so honouring it would silently stop linting a repo that asked to be linted, which " \
      "is worse than the false red the waiver was added to cure. NOTHING was certified. Fix the " \
      "DECLARATION, not this run: delete the `lint_lane: none` line from #{repo}'s row in " \
      "config/release_repos.yml so the rubocop lane is owed again (and dor-check demands it again). " \
      "If the toolchain above is stray rather than intended, remove it from the repo instead."
  end

  # The one-line remedy for the OTHER shape of this problem: a repo that declares
  # no waiver and whose rubocop cannot launch. The verdict there is RED and stays
  # RED (rule 1 — a missing binary waives nothing), but the red said only "the
  # COMMAND is the problem", which leaves a builder in a genuinely toolchain-less
  # repo with no route at all. This names the route without granting it: the fix is
  # a reviewed registry line, written by someone who has checked the repo really
  # has no lint lane. Returns nil for a repo that IS waived (it has its route).
  def undeclared_hint(repo)
    return nil if FullSuiteGate.lint_waived?(repo)

    "If #{repo.to_s.empty? ? 'this repo' : repo} genuinely ships NO rubocop — no .rubocop.yml, no " \
      "bin/rubocop, none in the Gemfile or gemspec — then it has no lint lane to fail and the honest fix " \
      "is to DECLARE that: add `lint_lane: none` to its row in config/release_repos.yml (studio-engine and " \
      "solana-studio are the existing cases). Do NOT point FULL_SUITE_RUBOCOP_CMD at a no-op — that records " \
      "a rubocop pass for a lint that never ran. And do not declare it to get past a rubocop this repo DOES " \
      "ship and that is merely broken: that is the red lane doing its job."
  end

  # Every lint-toolchain marker present in the tree at `root`, as repo-relative
  # labels for the refusal. Empty means the waiver's claim still holds.
  def markers(root)
    dir = root.to_s
    found = CONFIG_FILES.select { |name| File.file?(File.join(dir, name)) }
    found << BINSTUB if File.file?(File.join(dir, BINSTUB))
    found << "Gemfile" if matches?(File.join(dir, "Gemfile"), GEMFILE_RE)
    Dir.glob(File.join(dir, "*.gemspec")).sort.each do |spec|
      found << File.basename(spec) if matches?(spec, GEMSPEC_RE)
    end
    found
  end

  # True when `path` is a readable file containing a line matching `regex`. An
  # unreadable file is NOT a marker: this guard refuses a cert, so it must never
  # do so on a file it could not actually read.
  def matches?(path, regex)
    File.file?(path) && File.read(path).match?(regex)
  rescue SystemCallError
    false
  end
end
