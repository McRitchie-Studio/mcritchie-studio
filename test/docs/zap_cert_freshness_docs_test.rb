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
# the six behaviour tests and by the source-order pin on the gate's own ref
# preference, which is what actually goes red if the gate or git stops working the
# way the paragraph says.
#
# THE SECOND PASS (/tasks/refusal-names-wrong-checkout, 2026-09-09). The same false
# claim turned out to live in six more places, in bin/ and test/ rather than in prose
# — including the operator refusal bin/dor-check prints mid-verdict, and this file's
# own sibling fixtures, whose COMMENTS justified a correct fixture with the wrong
# reason. Correcting the doc alone would have left the code still saying it. The last
# three tests below pin exactly what those comments got wrong — WHICH of the gate's
# two checks catches WHICH case, that :mismatch establishes no cert-lane verdict at all,
# and that the remedy the refusal prints actually clears the state it is printed into.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/cert_evidence"
require_relative "../../bin/lib/full_suite_gate"
require_relative "../../bin/lib/review_tree_guard"

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

  # --- WHICH check catches WHICH case (/tasks/refusal-names-wrong-checkout) --
  #
  # bin/dor-check runs TWO checks over the SAME ref — the cert fingerprint and
  # ReviewTreeGuard's head check — and the comments and the operator-facing refusal
  # beside them explain which one bites for a given zap. That explanation was wrong
  # in six places at once: it said a push from "any other checkout" leaves the desk's
  # ref pre-zap, collapsing the worktree and clone cases exactly as the doc had.
  #
  # These two tests pin the division of labour to REF SHARING rather than to distance,
  # in the same house geometry and through the same functions the gate calls. They are
  # deliberately NOT a grep of the refusal text: a string pin dies at the next reword
  # and proves nothing about which check actually fires. Reword those messages freely;
  # break the mechanism they describe and these go red.

  def test_a_worktree_zap_is_caught_by_the_cert_while_the_head_check_stays_quiet
    with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)

      zap!(h[:zapdesk], "2\n")
      pr_head = capture(h[:remote], "rev-parse #{BRANCH}")
      head = ReviewTreeGuard.head_assessment(root: h[:builder], branch: BRANCH, pr_head: pr_head)

      assert_equal :stale, FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(h[:builder])),
                   "the shared ref moved, so the CERT is what catches a sibling-worktree zap"
      assert_equal :match, head[:state],
                   "the head check MUST stay quiet here — the desk's ref followed the push. Any comment " \
                   "or refusal claiming the head check is what catches a push from 'another checkout' " \
                   "is describing THIS case, and describing it wrongly."
      assert_equal "origin/#{BRANCH}", head[:ref],
                   "and it must read the SAME ref the cert hashes: if those diverge the two checks stop " \
                   "being complementary and neither explanation can be right"
    end
  end

  def test_a_clone_zap_is_caught_only_by_the_head_check_and_the_cert_says_fresh
    with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)

      zap!(h[:otherclone], "3\n")
      pr_head = capture(h[:remote], "rev-parse #{BRANCH}")
      head = ReviewTreeGuard.head_assessment(root: h[:builder], branch: BRANCH, pr_head: pr_head)

      assert_equal :fresh, FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(h[:builder])),
                   "independent refs, so the cert cannot see the push — it reads FRESH over a tree that " \
                   "is no longer the PR head. That is the HAZARDOUS reading, not the reassuring one."
      assert_equal :mismatch, head[:state],
                   "the head check is the ONLY thing between a clone-side zap and a green verdict, which " \
                   "is why the refusal it prints must not credit the cert with catching this"
      assert_equal capture(h[:builder], "rev-parse origin/#{BRANCH}"), head[:local_sha]
      refute_equal head[:pr_head], head[:local_sha],
                   "fixture: the desk and the PR head must differ or this proves nothing"
    end
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

  # --- the SAME backstop for the bin/ prose ----------------------------------
  #
  # THE HOLE THIS FILLS, measured on this task's first review pass: reverting BOTH
  # corrected bin/ sentences to the original false text reddened NOTHING — 163 runs,
  # 0 failures across test/docs, review_tree_guard_test and dor_check_zap_seams_test.
  # The MECHANISM above is well guarded (forcing same_commit? either way, or lane_status
  # to :fresh, reddens four of the tests above) and the doc has the backstop directly
  # overhead. The bin/ prose had nothing — and it is the half an operator actually reads
  # MID-VERDICT, at the moment they are deciding whether to trust the gate or route
  # around it. It has now been wrong twice.
  #
  # THESE ARE NOT A GREP FOR THE NEW WORDING. The task record forbids that and is right
  # to: a pin on today's phrasing dies at the next reword and proves nothing about the
  # gate. All three MEASURE FIRST, in the same house geometry and through the same two
  # functions review's gate-zero calls, and compare the prose to what they measured:
  #
  #   the first  measures that :mismatch is reachable with the lane BOTH ways, which is
  #              what makes naming a lane verdict in that refusal unsound at all;
  #   the second measures which verdict each case actually produces, and pins that the
  #              two comment passages bind them that way round;
  #   the third  measures the REMEDY — what the printed commands do to the lane and the
  #              head check when an operator actually runs them, in order.
  #
  # So reword any of them freely. Invert the pairing, collapse the two cases back under
  # one quantifier over "any other checkout", re-assert a state the check has not
  # established, or hand the operator a remedy that loops, and these go red.

  # The two states the ORIGINAL false sentences named, kept here as the one thing a
  # rewrite may not reintroduce. Located by CODE anchors — the condition that fires the
  # refusal, and the section rules around each comment — never by a phrase inside the
  # prose, so the wording stays free.
  COLLAPSED_QUANTIFIER = %r{\b(?:any other|another|some other)\s+checkout\b|\banywhere\s+else\b}i

  def source(rel) = File.read(File.join(ROOT, rel))

  # bin/dor-check's refusal literal, taken from its firing condition down to the next
  # branch. Anchored on the `if`, not on any sentence it prints.
  def head_refusal_literal
    body = source("bin/dor-check")[/if review_role && head_check\[:state\] == :mismatch\n(.*?)\n\s*elsif /m, 1]
    refute_nil body, "bin/dor-check no longer refuses on `head_check[:state] == :mismatch` — re-point this " \
                     "guard rather than deleting it; what the refusal may claim is still the live question"
    body
  end

  # The same refusal as the OPERATOR sees it, with Ruby's string-continuation seams
  # (a trailing backslash, a newline, and a re-opened quote) closed up and whitespace
  # flattened. Pins on the COMMANDS it prints read THIS and not the literal: where a
  # command falls in the source is a wrapping accident, and a guard a re-wrap turns red
  # is a guard that gets deleted rather than re-pointed.
  def head_refusal_text
    head_refusal_literal.gsub(/"\s*\\\s*\n\s*"/, "").gsub(/\s+/, " ")
  end

  # A comment block, de-hashed and reflowed into sentences. Both bounds are structural.
  def comment_sentences(rel, from:, to:)
    block = source(rel)[/#{from}(.*?)#{to}/m, 1]
    refute_nil block, "the #{rel} passage this pin covers is gone or its bounds moved — re-point it; the " \
                      "claim it carries is still live"
    block.lines.map { |l| l.sub(/\A\s*#\s?/, "").rstrip }.join(" ").squeeze(" ").split(/(?<=\.)\s+/)
  end

  # ONE push, measured: what does each case do to the desk's cert lane and head check?
  def verdicts_for(push_from)
    with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)
      zap!(h[push_from], "9\n")
      head = ReviewTreeGuard.head_assessment(root: h[:builder], branch: BRANCH,
                                             pr_head: capture(h[:remote], "rev-parse #{BRANCH}"))
      [FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(h[:builder])), head[:state]]
    end
  end

  def test_a_mismatch_does_not_fix_the_lane_so_the_refusal_may_not_name_one
    clone_only = verdicts_for(:otherclone)

    # THE COMPOUND CASE, and it is the HOUSE route rather than a contrivance: a reviewer
    # zaps from the throwaway SIBLING WORKTREE the zap protocol prescribes (lane STALE,
    # head :match, nothing refuses), and then anything with independent refs moves the
    # head again — GitHub's Update-branch button, which bin/dor-check's OWN base report
    # recommends by name. The clone has to take the zap first, exactly as GitHub would.
    compound = with_house do |h|
      certified = cert_tree_seen_from(h[:builder])
      checks = cert_for(certified)
      zap!(h[:zapdesk], "2\n")
      git!(h[:otherclone], "fetch -q origin #{BRANCH}")
      git!(h[:otherclone], "reset -q --hard origin/#{BRANCH}")
      zap!(h[:otherclone], "3\n")
      head = ReviewTreeGuard.head_assessment(root: h[:builder], branch: BRANCH,
                                             pr_head: capture(h[:remote], "rev-parse #{BRANCH}"))
      [FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(h[:builder])), head[:state]]
    end

    assert_equal [%i[fresh mismatch], %i[stale mismatch]], [clone_only, compound],
                 "the SAME refusal condition (:mismatch) is reachable with the cert lane BOTH ways. That is " \
                 "the whole reason the refusal below may not report one — it has not established it."

    refusal = head_refusal_literal
    refute_match(/\b(?:not|never) moved\b|\bunmoved\b|\bstill pre-(?:zap|push)\b/i, refusal,
                 "the refusal claims the ref's HISTORY. :mismatch says only that the ref does not carry the " \
                 "PUSHED HEAD; the compound case measured above moved that ref and still reaches :mismatch.")
    refute_match(/\bFRESH\b|\bSTALE\b/i, refusal,
                 "the refusal names a cert lane verdict. Measured directly above: :mismatch holds with the " \
                 "lane FRESH and with it STALE, so this message cannot know which — and in the stale arm the " \
                 "SAME errors array already carries `full-suite: STALE` from suite_evidence_error. One " \
                 "verdict contradicting itself is this task's defect. Describe THIS ref; let the lane speak.")
  end

  def test_the_gate_comments_bind_each_verdict_to_the_case_that_produces_it
    worktree_lane, worktree_head = verdicts_for(:zapdesk)
    clone_lane, clone_head = verdicts_for(:otherclone)

    # The expectations below are MEASURED, not written down: flip the mechanism and the
    # prose these pins demand flips with it.
    assert_equal %i[stale match], [worktree_lane, worktree_head]
    assert_equal %i[fresh mismatch], [clone_lane, clone_head]
    worktree_verdict = worktree_lane.to_s.upcase
    clone_verdict = clone_lane.to_s.upcase

    passages = {
      "bin/lib/review_tree_guard.rb" =>
        comment_sentences("bin/lib/review_tree_guard.rb",
                          from: /^# ── SEAM 1:.*?\n/, to: /^# ── SEAM 2:/),
      "bin/dor-check" =>
        comment_sentences("bin/dor-check",
                          from: /^  # SEAM 1 — REFUSES,/, to: /^  head_check = ReviewTreeGuard\.head_assessment\(/)
    }

    passages.each do |file, sentences|
      names_worktree = ->(s) { s.match?(/worktree/i) }
      names_independent = ->(s) { s.match?(/\bclone\b|INDEPENDENT/i) }

      assert sentences.any? { |s| names_worktree.call(s) && s.include?(worktree_verdict) },
             "#{file}: no sentence binds #{worktree_verdict} to the SIBLING WORKTREE case — the shared-ref, " \
             "house case, measured #{worktree_verdict} in this very test. A passage that explains the gate " \
             "without saying which push it catches is how the collapsed claim got in twice."
      assert sentences.any? { |s| names_independent.call(s) && s.include?(clone_verdict) },
             "#{file}: no sentence binds #{clone_verdict} to the INDEPENDENT-REFS case (a separate clone, " \
             "another machine, Update-branch) — the case this check is the only thing to catch"

      # A straight SWAP keeps both nouns and both verdicts, so presence alone is not a
      # pin. Sentences naming exactly ONE case must carry that case's verdict and not
      # the other's; a sentence naming BOTH is a comparison and is left alone.
      inverted = sentences.select do |s|
        (names_worktree.call(s) && !names_independent.call(s) && s.include?(clone_verdict)) ||
          (names_independent.call(s) && !names_worktree.call(s) && s.include?(worktree_verdict))
      end
      assert_empty inverted, "#{file}: a sentence gives one case the OTHER case's verdict — the two are " \
                             "inverted, which is the partial break a half-remembered rule produces"
    end

    # The falsified absolute itself, in every bin/ site that carried it. This is what
    # the reviewer's mutation restores, and it is a refute on the DEAD wording only —
    # it constrains nothing about how the correction is phrased.
    {
      "bin/lib/review_tree_guard.rb" => passages["bin/lib/review_tree_guard.rb"].join(" "),
      "bin/dor-check comment" => passages["bin/dor-check"].join(" "),
      "bin/dor-check refusal" => head_refusal_literal,
      "bin/lib/ci_status.rb" => comment_sentences("bin/lib/ci_status.rb",
                                                  from: /^  # PURE\. The PR's head commit,/,
                                                  to: /^  def self\.head_oid/).join(" ")
    }.each do |where, text|
      refute_match COLLAPSED_QUANTIFIER, text,
                   "#{where}: the ref-sharing claim is collapsed back under a quantifier over CHECKOUTS " \
                   "('another checkout', 'anywhere else'). Measured above: a sibling worktree is another " \
                   "checkout and it DOES move the ref. The test is ref sharing, not distance."
    end
  end

  # --- and the REMEDY it prints, measured end to end -------------------------
  #
  # The reviewer raised this against the DOC's copy of the remedy and marked it noted
  # only. Measured here, it is true of the REFUSAL's copy too — and that is the one an
  # operator follows mid-verdict, which is the same reason :3198 was the blocker. In
  # this file's own house geometry, one independent-refs zap:
  #
  #   clone zap, no fetch           lane=fresh  head=mismatch   the refusal fires
  #   after `git fetch`             lane=stale  head=match      refusal clears...
  #   after fetch + re-certify      lane=stale  head=match      ...and LOOPS
  #   after fetch + MOVE + re-cert  lane=fresh  head=match      cleared
  #
  # The loop is not a gate bug. bin/full-suite-check fingerprints the WORKING tree
  # (its own dirty-tree guard says so at bin/full-suite-check:221) while
  # review_fingerprint hashes origin/<branch>, and a bare fetch moves the second and
  # not the first. So a remedy that steps straight from `git fetch` to
  # `bin/full-suite-check` hands the operator back the verdict they started with.
  #
  # This pins the COMMANDS and their ORDER, never the sentences around them. Reword the
  # remedy however you like; drop the step that moves this checkout onto the fetched
  # head, or put the re-certify ahead of it, and this goes red.
  def test_the_printed_remedy_clears_the_state_it_is_printed_into
    fetch_only, fetch_then_recert, fetch_move_recert = with_house do |h|
      desk = h[:builder]
      # What bin/full-suite-check actually stamps: the WORKING tree, not a ref.
      cert = cert_for(FullSuiteGate.fingerprint(desk))
      zap!(h[:otherclone], "3\n")

      grade = lambda do |checks|
        [FullSuiteGate.lane_status(checks, LANE, cert_tree_seen_from(desk)),
         ReviewTreeGuard.head_assessment(root: desk, branch: BRANCH,
                                         pr_head: capture(h[:remote], "rev-parse #{BRANCH}"))[:state]]
      end

      assert_equal %i[fresh mismatch], grade.call(cert),
                   "precondition: this is the state the refusal is printed into"

      git!(desk, "fetch -q origin #{BRANCH}")
      after_fetch = grade.call(cert)
      # Re-certify RIGHT HERE, which is what the remedy used to say to do.
      after_recert = grade.call(cert_for(FullSuiteGate.fingerprint(desk)))
      git!(desk, "merge --ff-only origin/#{BRANCH}")
      after_move = grade.call(cert_for(FullSuiteGate.fingerprint(desk)))

      [after_fetch, after_recert, after_move]
    end

    assert_equal %i[stale match], fetch_only,
                 "a bare fetch DOES clear the head refusal — which is why the message keeps recommending it"
    assert_equal %i[stale match], fetch_then_recert,
                 "re-certifying without moving the checkout re-stamps the tree that is already there, so the " \
                 "lane stays STALE: the operator followed the remedy and got the same verdict back"
    assert_equal %i[fresh match], fetch_move_recert,
                 "only moving this checkout onto the fetched head BEFORE re-certifying clears both"

    # --- AND IT MUST NAME THE TREE IT ACTS ON (/tasks/remedy-command-lacks-directory) --
    #
    # Everything above measures the remedy from INSIDE the graded checkout. The operator
    # is not standing there: bin/dor-check:1176-1180 says `--gate-role review` is run from
    # the repo's PRIMARY, which sits on release or main by SOP, and the gate re-roots to
    # the desk by itself. So the directory a pasted command acts on is whichever tree the
    # reviewer happens to be in — and the move above is the FIRST MUTATING command this
    # refusal has ever printed. The previous remedy was `git fetch`, harmless from
    # anywhere; that is why nobody had to think about this before.
    poisoned_primary, spared_primary, moved_desk = with_house do |h|
      # The SOP geometry, built for real: the primary sits on main, BEHIND the feature
      # head. Note `-B main origin/#{BRANCH}` and not a bare `-B main` — with only feat/x
      # ever pushed, the clone leaves this primary on an UNBORN branch, where `git
      # rev-parse HEAD` echoes the literal "HEAD" on stdout instead of failing, and every
      # sha comparison below would then compare two copies of that string.
      git!(h[:primary], "checkout -q -B main origin/#{BRANCH}")
      pristine = capture(h[:primary], "rev-parse HEAD")
      zap!(h[:otherclone], "7\n")
      git!(h[:primary], "fetch -q origin #{BRANCH}")
      git!(h[:builder], "fetch -q origin #{BRANCH}")

      # (a) the command WITHOUT a directory, run where the reviewer actually stands
      system("git -C #{h[:primary]} merge --ff-only origin/#{BRANCH} >/dev/null 2>&1")
      bare = capture(h[:primary], "rev-parse HEAD")
      git!(h[:primary], "reset -q --hard #{pristine}")

      # (b) the same command scoped to the graded checkout, which is what it prints now
      system("git -C #{h[:builder]} merge --ff-only origin/#{BRANCH} >/dev/null 2>&1")
      [bare != pristine,
       capture(h[:primary], "rev-parse HEAD") == pristine,
       capture(h[:builder], "rev-parse HEAD") == capture(h[:builder], "rev-parse origin/#{BRANCH}")]
    end

    assert poisoned_primary,
           "fixture: the unscoped command must move the primary, or the pin below proves nothing. It " \
           "fast-forwards main onto the feature head with exit 0 and a `Fast-forward` message — nothing is " \
           "pushed, but every later gate and every bin/release read then works from a poisoned checkout."
    assert spared_primary,
           "scoping to the graded checkout leaves the reviewer's own tree where it was — the whole point"
    assert moved_desk,
           "scoping still does the job it is printed for: the GRADED checkout lands on the fetched head"

    remedy = head_refusal_text[/git (?:-C \S+ )?fetch origin.*/m]
    refute_nil remedy, "the refusal no longer names `git [-C <root>] fetch origin <branch>` — re-point this " \
                       "guard rather than deleting it; whether the printed remedy works is still the live " \
                       "question"

    # Every command printed AGAINST THE PR BRANCH must name the tree. Commands naming
    # some OTHER ref are exempt on purpose: a recovery note for the primary's own
    # upstream is run where the operator is standing and correctly carries no -C.
    unscoped = remedy.scan(/git (?!-C )(?:[a-z-]+ )+?origin[ \/]\#\{\w+\}/)
    assert_empty unscoped,
                 "the refusal prints #{unscoped.length} command(s) against the PR branch with no directory " \
                 "(#{unscoped.inspect}). Measured directly above: pasted from the primary this very gate " \
                 "tells reviewers to run from, the bare fast-forward moves THAT checkout onto the feature " \
                 "head. Scope them — `git -C \#{diff_root} …` — so the printed command acts on the tree the " \
                 "sentence around it is talking about."

    move = remedy.index(/git -C \S+ (?:merge --ff-only|pull|reset --hard|checkout)/)
    refute_nil move,
               "the remedy names no DIRECTORY-SCOPED command that MOVES the graded checkout onto the fetched " \
               "head. Measured directly " \
               "above: fetch-then-re-certify leaves the lane STALE, because bin/full-suite-check hashes the " \
               "WORKING tree and a fetch does not move it. A remedy that loops is the same defect as a " \
               "diagnosis that lies — the operator trusts it once and then stops trusting the gate."
    recert = remedy.rindex("bin/full-suite-check")
    assert recert.nil? || move < recert,
           "the remedy's LAST word on bin/full-suite-check comes BEFORE the command that moves this checkout. " \
           "Measured above, a cert taken in that order stamps the tree the operator already had."

    # AND THE DOC'S COPY OF THE SAME REMEDY, both bullets. Correcting the gate and not
    # the protocol leaves two authorities disagreeing about one measured fact, and an
    # operator who reads the doc first never sees the correction. That split is how this
    # claim survived its first pass; it does not get to be how the remedy survives.
    paragraph = File.read(DOC)[/\*\*Expect the cert to go STALE.*?(?=\n\*\*A base that moves)/m]
    refute_nil paragraph, "the cert-freshness paragraph is gone or renamed — re-point this guard; the remedy " \
                          "it carries is measured directly above and is still live"

    bullets = paragraph.split(/^- /).drop(1).select { |b| b.include?("bin/full-suite-check") }
    refute_empty bullets, "neither case's bullet tells the reader how to re-certify any more — re-point this pin"
    bullets.each do |bullet|
      lead = bullet[/\A\*\*(.+?)\*\*/m, 1].to_s.gsub(/\s+/, " ")[0, 60]
      # Flattened for the same reason head_refusal_text is: markdown re-wraps, and a
      # command split across two lines is still one command to the reader who copies it.
      flat = bullet.gsub(/\s+/, " ")
      unscoped_here = flat.scan(/git (?!-C )(?:[a-z-]+ )+?origin\/<branch>/)
      assert_empty unscoped_here,
                   "zap-protocol.md, bullet «#{lead}»: prints #{unscoped_here.inspect} against the PR branch " \
                   "with no directory. Measured above, that command run from the primary fast-forwards the " \
                   "PRIMARY. The gate and this doc are the two authorities on one remedy — correcting only " \
                   "one is how the false claim in this same passage survived its first pass."
      moved = flat.index(/git -C <\w+> (?:merge --ff-only|pull|reset --hard|checkout)/)
      certified = flat.rindex("bin/full-suite-check")
      refute_nil moved,
                 "zap-protocol.md, bullet «#{lead}»: sends the reader to bin/full-suite-check with no command " \
                 "that moves their checkout onto the pushed head. Measured above, in BOTH cases, that cert " \
                 "re-stamps the tree already there and the lane stays STALE — the doc would be walking them " \
                 "into the loop bin/dor-check's refusal now steers them out of."
      assert moved < certified,
             "zap-protocol.md, bullet «#{lead}»: the certify step comes before the move step. Order is the " \
             "whole finding — a cert taken before the move stamps the tree the reader already had."
    end
  end

  # --- AND THE CASE THE MOVE ITSELF CAN REFUSE (/tasks/remedy-command-lacks-directory)
  #
  # The remedy above ends in a FAST-FORWARD, and a fast-forward can refuse. Measured
  # below in the same house geometry, on a desk carrying its own unpushed commit:
  #
  #   merge --ff-only   exit != 0   nothing moved     safe — and it DEAD-ENDS there
  #   merge --no-ff     exit 0      tree != PR head   git's own hint, and it SUCCEEDS
  #   rebase (alone)    exit 0      tree != PR head   git's other hint
  #   reset --hard      exit 0      tree == PR head   and the desk's commit is GONE
  #
  # So an operator who takes either hint git prints certifies a tree that never merges,
  # and one who takes neither has been told nothing at all. A remedy that dead-ends is
  # the same defect as one that loops (the test above): each spends the reviewer's trust
  # in the gate once and does not get it back. The pins are on COMMANDS — that the
  # escape hatch is named and scoped, that the operator is told to LOOK before it
  # discards, and that the hint measured here to land the wrong tree is never printed as
  # something to run.
  def test_the_remedy_names_a_next_step_when_the_fast_forward_refuses
    measured = with_house do |h|
      desk = h[:builder]
      zap!(h[:otherclone], "8\n")                  # the PR head moves out from under the desk
      # DISJOINT from what the zap touches, so --no-ff below merges CLEANLY. A conflict
      # here would prove only that git stopped; the finding is that it does not stop.
      File.write(File.join(desk, "local_only.rb"), "still mine\n")
      git!(desk, "add -A")
      git!(desk, "commit -q -m 'unpushed local work'")
      git!(desk, "fetch -q origin #{BRANCH}")
      diverged = capture(desk, "rev-parse HEAD")
      pr_tree = capture(desk, "rev-parse origin/#{BRANCH}^{tree}")

      try = lambda do |args|
        ok = system("git -C #{desk} #{args} >/dev/null 2>&1")
        landed = capture(desk, "rev-parse HEAD^{tree}")
        git!(desk, "reset -q --hard #{diverged}")
        [ok, landed == pr_tree]
      end

      { "merge --ff-only" => try.call("merge --ff-only origin/#{BRANCH}"),
        "merge --no-ff"   => try.call("merge --no-ff --no-edit origin/#{BRANCH}"),
        "rebase"          => try.call("rebase origin/#{BRANCH}"),
        "reset --hard"    => try.call("reset --hard origin/#{BRANCH}") }
    end

    assert_equal({ "merge --ff-only" => [false, false],
                   "merge --no-ff"   => [true,  false],
                   "rebase"          => [true,  false],
                   "reset --hard"    => [true,  true] },
                 measured,
                 "[did it run?, did it land the PR head tree?] per candidate move. BOTH moves git prints " \
                 "as hints succeed and BOTH land a tree that is not the PR head — which is why the refusal " \
                 "may not stop at the fast-forward and leave the operator holding git's advice.")

    refusal = head_refusal_text
    refute_match(/git (?:-C \S+ )?merge --no-ff/, refusal,
                 "the refusal prints git's own --no-ff hint as a command to RUN. Measured directly above it " \
                 "succeeds and lands a tree that is not the PR head's, so a cert taken after it describes a " \
                 "tree that never merges — the remedy steering into the very defect this gate exists to catch")
    assert_match(/git -C \S+ reset --hard origin\/\#\{\w+\}/, refusal,
                 "the refusal names no scoped command that RESOLVES a refused fast-forward. Measured above, " \
                 "`reset --hard origin/<branch>` is the only candidate that lands the PR head tree, and it " \
                 "DISCARDS the desk's own commit — which is exactly why the refusal must name it out loud " \
                 "instead of leaving the operator to pick one of git's two wrong hints")
    assert_match(/git -C \S+ log [^)]*origin\/\#\{\w+\}\.\.HEAD/, refusal,
                 "the refusal reaches `reset --hard` without first naming a command that shows WHAT would be " \
                 "discarded. On a review lane that diverged commit is usually sitting on the BUILDER'S desk; " \
                 "a remedy that says destroy-it-to-proceed without saying look-first is one that eats work")

    # The doc's copy of the same two claims. Two authorities, one remedy — and this
    # passage is where a correction applied to only one of them last time.
    paragraph = File.read(DOC)[/\*\*Expect the cert to go STALE.*?(?=\n\*\*A base that moves)/m]
    refute_nil paragraph, "the cert-freshness paragraph is gone or renamed — re-point this guard"
    flat = paragraph.gsub(/\s+/, " ")
    refute_match(/git (?:-C <\w+> )?merge --no-ff/, flat,
                 "zap-protocol.md prints the --no-ff hint as a command to run — measured above, it lands the " \
                 "wrong tree. Correcting the gate and not the protocol leaves two authorities disagreeing.")
    assert_match(/git -C <\w+> reset --hard origin\/<branch>/, flat,
                 "zap-protocol.md never names the scoped command that resolves a refused fast-forward, so a " \
                 "reader who hits one is left with git's hints — both measured wrong above")
  end
end
