# frozen_string_literal: true

# [docs] WHEN DOES A ZAP INVALIDATE THE BUILDER'S CERT? — the zap protocol's
# cert-freshness claim, pinned against the behaviour it describes.
#
#   ruby -Itest test/docs/zap_cert_freshness_docs_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT THIS CLOSES (/tasks/zap-doc-misstates-cert). docs/agents/modules/
# zap-protocol.md told a reviewer that pushing a zap from anywhere OTHER than the
# builder's desk leaves the desk's ref pre-zap, so the cert "reads FRESH". That is
# true of a separate CLONE and FALSE of a WORKTREE — and the protocol's own recipes
# cut the throwaway zap desk as a worktree (`$(dirname "$(git rev-parse
# --git-common-dir)")/.worktrees/zap-<slug>`), so the case the doc described as
# ordinary was the one it could almost never produce. Carl hit it zapping
# studio-engine #305 on 2026-09-08: he followed the doc, expected FRESH, and the
# gate correctly refused a stale cert. The cost was not a bad merge; it was a
# reviewer mid-verdict deciding whether to trust the doc or the gate.
#
# WHY THIS IS A BEHAVIOUR TEST AND NOT A GREP FOR THE SENTENCE. The claim is about
# what git and FullSuiteGate DO, so a prose check could only certify that the new
# wording exists — it would pass just as happily over a differently-worded lie, and
# it would not notice if the gate changed underneath the doc. So the load-bearing
# tests below run REAL repositories in the real house geometry (one primary, two
# worktrees of it, and one independent clone) and grade with the SAME functions
# bin/dor-check's review gate-zero uses: FullSuiteGate.fingerprint_of_ref for the
# hash and FullSuiteGate.lane_status for the FRESH/STALE verdict. Mock git here and
# the mock IS the subject.
#
# THE LIMIT, STATED PLAINLY. No runnable assertion can prove that a paragraph of
# English describes these measurements correctly — an arbitrarily reworded false
# mechanism is not detectable by string matching. So the prose half is deliberately
# NARROW: it pins only that the cert paragraph still binds each verdict to the right
# case and no longer carries the falsified absolute. The mechanism itself is held by
# the four behaviour tests and by the source-order pin on the gate's own ref
# preference, which is what actually goes red if the gate or git stops working the
# way the paragraph says.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/cert_evidence"
require_relative "../../bin/lib/full_suite_gate"

class ZapCertFreshnessDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC = File.join(ROOT, "docs/agents/modules/zap-protocol.md")
  BRANCH = "feat/x"
  LANE = CertEvidence::TEST_LANE

  # THE HOUSE GEOMETRY, built for real:
  #
  #   remote.git                     the GitHub side
  #   primary/                       the repo's primary checkout (a clone)
  #   primary/.worktrees/builder/    the BUILDER'S DESK — what --gate-role review
  #                                  re-roots to, and where the cert hash is read
  #   primary/.worktrees/zapdesk/    the THROWAWAY the zap protocol tells you to cut
  #   otherclone/                    a SEPARATE clone — independent refs
  #
  # builder and zapdesk are SIBLING worktrees: neither is the other's parent, which
  # is the exact shape a reviewer stands in. Nothing here fetches unless a test asks
  # — bin/dor-check never fetches either, and that is the condition, not an oversight.
  def with_house
    Dir.mktmpdir("zap-cert") do |dir|
      remote = File.join(dir, "remote.git")
      primary = File.join(dir, "primary")
      builder = File.join(primary, ".worktrees", "builder")
      zapdesk = File.join(primary, ".worktrees", "zapdesk")
      otherclone = File.join(dir, "otherclone")

      git!(nil, "init -q --bare #{remote}")
      seed!(dir, remote)
      git!(nil, "clone -q #{remote} #{primary}")
      identity!(primary)
      git!(primary, "worktree add -q #{builder} --detach origin/#{BRANCH}")
      git!(primary, "worktree add -q #{zapdesk} --detach origin/#{BRANCH}")
      git!(nil, "clone -q #{remote} #{otherclone}")
      identity!(otherclone)
      git!(otherclone, "checkout -q -B #{BRANCH} origin/#{BRANCH}")

      yield(primary: primary, builder: builder, zapdesk: zapdesk,
            otherclone: otherclone, remote: remote)
    end
  end

  def seed!(dir, remote)
    seed = File.join(dir, "seed")
    FileUtils.mkdir_p(seed)
    git!(seed, "init -q")
    identity!(seed)
    File.write(File.join(seed, "feature.rb"), "1\n")
    git!(seed, "add -A")
    git!(seed, "commit -q -m feature")
    git!(seed, "branch -M #{BRANCH}")
    git!(seed, "remote add origin #{remote}")
    git!(seed, "push -q origin #{BRANCH}")
  end

  # NOT `setup` — that is Minitest's per-test hook, and shadowing it with a
  # one-argument method makes every test in this file error before it runs.
  def identity!(dir)
    git!(dir, "config user.email tester@example.com")
    git!(dir, "config user.name tester")
  end

  def git!(dir, args)
    cmd = dir ? "git -C #{dir} #{args}" : "git #{args}"
    assert system("#{cmd} >/dev/null 2>&1"), "failed: #{cmd}"
  end

  def capture(dir, args)
    IO.popen(["git", "-C", dir, *args.split], err: File::NULL, &:read).to_s.strip
  end

  # A zap: one bounded edit, committed and pushed to the PR branch with the exact
  # refspec form the protocol's recipes use.
  def zap!(from, content)
    File.write(File.join(from, "feature.rb"), content)
    git!(from, "add -A")
    git!(from, "commit -q -m 'zap: bounded fix'")
    git!(from, "push -q origin HEAD:refs/heads/#{BRANCH}")
  end

  # The builder's recorded cert, as bin/full-suite-check writes it.
  def cert_for(fingerprint)
    [FullSuiteGate.evidence_line(LANE, fingerprint, "1234 runs, 0 failures")]
  end

  # What the review gate-zero reads: bin/dor-check's review_fingerprint hashes
  # origin/<branch> in the desk it re-rooted to.
  def cert_tree_seen_from(desk)
    FullSuiteGate.fingerprint_of_ref(desk, "origin/#{BRANCH}")
  end

  # --- the mechanism the doc names ------------------------------------------

  def test_the_cert_fingerprint_is_a_tree_hash_not_a_commit_sha
    with_house do |h|
      tree = cert_tree_seen_from(h[:builder])
      commit = capture(h[:builder], "rev-parse origin/#{BRANCH}")

      refute_nil tree
      refute_equal commit, tree,
                   "the cert is fingerprinted against the TREE, not the commit — a doc that says " \
                   "otherwise would send a reviewer comparing the wrong two hashes"
      assert_equal capture(h[:builder], "rev-parse origin/#{BRANCH}^{tree}"), tree
      assert_equal FullSuiteGate.fingerprint(h[:builder]), tree,
                   "a clean desk's WORKING-tree fingerprint must equal the committed ref's tree hash — " \
                   "that content-addressed equality is what lets a cert taken before the commit still " \
                   "grade after the push"
    end
  end

  def test_worktrees_of_one_repo_share_the_remote_tracking_ref_store
    with_house do |h|
      common = ->(dir) { File.realpath(File.expand_path(capture(dir, "rev-parse --git-common-dir"), dir)) }
      private_dir = ->(dir) { File.realpath(File.expand_path(capture(dir, "rev-parse --git-dir"), dir)) }

      assert_equal common.call(h[:primary]), common.call(h[:builder])
      assert_equal common.call(h[:primary]), common.call(h[:zapdesk]),
                   "sibling worktrees must resolve to ONE ref store — this sharing is the whole reason a " \
                   "zap pushed from a throwaway desk invalidates the builder's cert"
      refute_equal private_dir.call(h[:builder]), private_dir.call(h[:zapdesk]),
                   "each worktree still has its own git dir; only HEAD and a few refs live there"
      refute_equal common.call(h[:builder]), common.call(h[:otherclone]),
                   "a separate clone must NOT share the ref store — that is the case the doc's FRESH " \
                   "reading actually belongs to"
    end
  end

  # --- the two outcomes the doc must tell apart ------------------------------

  def test_a_zap_pushed_from_a_sibling_worktree_makes_the_cert_stale
    with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)
      assert_equal :fresh, FullSuiteGate.lane_status(checks, LANE, certified)

      zap!(h[:zapdesk], "2\n")

      after = cert_tree_seen_from(h[:builder])
      refute_equal certified, after,
                   "a push from a SIBLING WORKTREE moves the shared origin/#{BRANCH} the gate hashes, " \
                   "with no fetch in the builder's desk"
      assert_equal :stale, FullSuiteGate.lane_status(checks, LANE, after),
                   "the cert MUST read STALE here — this is the house case (worktrees are the house desk) " \
                   "and the refusal is the guard working, not a bug in the gate"
      assert_equal capture(h[:remote], "rev-parse #{BRANCH}^{tree}"), after,
                   "and the tree it went stale against is the real PR head's"
    end
  end

  def test_a_zap_pushed_from_a_separate_clone_leaves_the_cert_falsely_fresh
    with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)

      zap!(h[:otherclone], "3\n")

      after = cert_tree_seen_from(h[:builder])
      assert_equal certified, after,
                   "a separate clone's refs are independent, so the desk's origin/#{BRANCH} stays pre-zap"
      assert_equal :fresh, FullSuiteGate.lane_status(checks, LANE, after)
      refute_equal capture(h[:remote], "rev-parse #{BRANCH}^{tree}"), after,
                   "and THAT is why FRESH is the dangerous reading, not the safe one: the cert is green " \
                   "over a tree that is no longer the PR head"

      # The read never fetches on its own — the same property bin/dor-check relies on.
      git!(h[:builder], "fetch -q origin #{BRANCH}")
      assert_equal :stale, FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(h[:builder])),
                   "only an explicit fetch corrects it, which is why the head check — not the cert — is " \
                   "what catches a clone-side push"
    end
  end

  # --- the gate still works the way the paragraph says -----------------------

  def test_the_review_gate_hashes_the_ref_the_doc_names
    source = File.read(File.join(ROOT, "bin/dor-check"))
    body = source[/def review_fingerprint\(root, branch\).*?\n  end\n/m]

    refute_nil body, "bin/dor-check no longer defines review_fingerprint(root, branch) — the doc's " \
                     "description of WHAT the gate hashes must be re-verified before this guard is edited"
    assert_match(/fingerprint_of_first_ref\(root, "origin\/#\{branch\}", branch\)/, body,
                 "the doc says the gate hashes origin/<branch> in the desk (falling back to the local " \
                 "branch). If that preference changes, the cert paragraph is wrong again.")
  end

  # --- the narrow prose backstop (see THE LIMIT in the header) ---------------

  def test_the_doc_tells_the_worktree_and_clone_cases_apart
    paragraph = File.read(DOC)[/\*\*Expect the cert to go STALE.*?(?=\n\*\*A base that moves)/m]

    refute_nil paragraph, "the cert-freshness paragraph is gone or renamed — re-point this guard rather " \
                          "than deleting it; the claim it covers is still live"
    assert_match(/worktree/i, paragraph)
    assert_match(/clone/i, paragraph)
    assert_match(/STALE/, paragraph)
    refute_match(/push it from anywhere else/i, paragraph,
                 "the falsified absolute: 'anywhere else' collapses the worktree and clone cases, which " \
                 "is exactly the misstatement this task fixed")

    # Presence alone is NOT a pin. A straight SWAP of the two bullets keeps both nouns,
    # both verdicts, and the old phrase still absent — so the checks above stay green over
    # an exactly-inverted doc, which is the partial break a half-remembered rule produces.
    # Bind each verdict to its own case.
    leads = paragraph.scan(/^- \*\*(.+?)\*\*/m).flatten
    refute_empty leads, "the two cases are no longer bolded bullet leads — re-point this pin"
    assert leads.any? { |l| l =~ /worktree/i && l.include?("STALE") },
           "no bullet lead assigns STALE to the WORKTREE case (the shared-ref, house case)"
    assert leads.any? { |l| l =~ /clone/i && l.include?("FRESH") },
           "no bullet lead assigns FRESH to the CLONE case (the independent-ref, dangerous reading)"
    refute leads.any? { |l| l =~ /worktree/i && l.include?("FRESH") },
           "a bullet lead calls the WORKTREE case FRESH — the two cases are inverted"
    refute leads.any? { |l| l =~ /clone/i && l.include?("STALE") },
           "a bullet lead calls the CLONE case STALE — the two cases are inverted"
  end
end
