# frozen_string_literal: true

# `bin/release retro`: the doc, the runner payload and follow-up filing.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_retro_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliRetroTest < ReleaseCliHarness
  def test_retro_writes_the_doc_to_disk_in_non_interactive_mode
    require "tmpdir"
    Dir.mktmpdir do |dir|
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      # --yes → fully non-interactive (no TTY prompt); an explicit slug positional.
      out = run_cli(["rel-retro", "--yes"], call: "retro", setup: setup)

      path = File.join(dir, "retro-rel-retro.md")
      assert File.exist?(path), "retro writes the durable doc: #{out}"
      assert_includes File.read(path), "# Release Retro — rel-retro"
      assert_includes out, "wrote"
    end
  end

  def test_retro_dry_run_previews_without_writing
    require "tmpdir"
    Dir.mktmpdir do |dir|
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      out = run_cli(["rel-retro", "--dry-run"], call: "retro", setup: setup)

      refute File.exist?(File.join(dir, "retro-rel-retro.md")), "a dry-run writes nothing"
      assert_includes out, "DRY RUN"
      assert_includes out, "would write retro doc"
    end
  end

  def test_retro_resolves_the_default_release_when_no_slug_is_given
    require "tmpdir"
    Dir.mktmpdir do |dir|
      # No positional slug → CLI passes nil; the (stubbed) resolver returns the
      # current/last-shipped release's slug, which the CLI writes the doc for.
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      run_cli(["--yes"], call: "retro", setup: setup)
      assert File.exist?(File.join(dir, "retro-rel-retro.md")), "default-release retro still writes a doc"
    end
  end

  def test_retro_collects_repeated_answer_flags_into_the_runner_payload
    require "tmpdir"
    Dir.mktmpdir do |dir|
      # Capture the snippet the CLI hands the (server-side) renderer: the stubbed
      # conductor echoes it back so we can prove the flags rode through. The
      # payload now rides as a Base64 blob (see the round-trip test below), so we
      # decode it rather than grep for the raw text.
      capture = <<~RUBY
        def conductor(ruby, read_only: false)
          File.write(#{File.join(dir, 'snippet.txt').inspect}, ruby)
          { "slug" => "rel-retro", "markdown" => "# Release Retro — rel-retro\\n" }
        end
      RUBY
      # The bin/triage stub is not optional decoration: --followup drives retro
      # into its filing block, and unstubbed that block shelled out to the REAL
      # bin/triage against the production board — this exact test filed 39 live
      # "fix flake" findings into the operator's inbox, one per suite run.
      _log, sh_stub = retro_sh_stub(dir)
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{capture}; #{sh_stub})
      run_cli(["rel-retro", "--yes", "--worked", "fast review", "--friction", "flaky e2e", "--followup", "fix flake"],
              call: "retro", setup: setup)

      answers = decode_retro_payload(File.read(File.join(dir, "snippet.txt")))
      assert_includes answers["worked"], "fast review", "--worked rides into the render payload"
      assert_includes answers["friction"], "flaky e2e", "--friction rides into the render payload"
      assert_includes answers["followups"], "fix flake", "--followup rides into the render payload"
    end
  end

  # --- retro follow-up identity + idempotency --------------------------------
  # 38 of 84 open findings were byte-identical "fix flake" entries: the title was
  # the follow-up's first 8 words (so every short follow-up collapsed to the same
  # title) AND every run refiled every follow-up. Both halves are pinned here,
  # and BOTH DIRECTIONS are pinned — under-filing (a duplicate) is visible at
  # /triage, but over-suppression silently loses a real finding, so the
  # "two different follow-ups both file" tests matter most.

  # [unit] a follow-up too short to identify itself carries its release slug, so
  # two REAL occurrences from different releases stay distinguishable.
  def test_unit_a_vague_retro_followup_title_carries_its_release_slug
    a = eval_helper(%(retro_followup_title("fix flake", "rel-a")))
    b = eval_helper(%(retro_followup_title("fix flake", "rel-b")))

    assert_includes a, "fix flake", "the operator's words survive"
    assert_includes a, "rel-a", "a vague title carries the release that raised it"
    refute_equal a, b, "the same vague text from two releases must NOT collapse to one title"
  end

  # [unit] …and a follow-up that already identifies itself is left alone, so the
  # slug tag stays a repair for generic text rather than noise on every title.
  def test_unit_an_identifying_retro_followup_title_is_not_slug_tagged
    title = eval_helper(%(retro_followup_title("board filter test reddens on a racing 404", "rel-a")))

    refute_includes title, "rel-a", "a self-identifying follow-up needs no slug crutch"
    assert_equal "board filter test reddens on a racing 404", title
  end

  # [unit] a truncated title SAYS it is truncated — the old code silently handed
  # back a prefix that read like the whole finding.
  def test_unit_a_long_retro_followup_title_is_marked_as_truncated
    long = (1..12).map { |i| "word#{i}" }.join(" ")
    title = eval_helper(%(retro_followup_title(#{long.inspect}, "rel-a")))

    assert_includes title, "word8", "the title keeps its leading words"
    refute_includes title, "word9", "…and stops at the window"
    assert_includes title, "…", "a truncated title must show that it is a prefix"
  end

  # [unit] the guard is VERBATIM on title AND body. Title-only or fuzzy matching
  # would swallow a genuinely distinct finding — worse than a duplicate, because
  # a duplicate is visible at /triage and a swallowed finding is not.
  def test_unit_the_duplicate_guard_matches_title_and_body_verbatim
    rows = [{ "title" => "t", "body" => "b" }]
    same  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b")))
    body  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b2")))
    title = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t2", "b")))
    near  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b ")))

    assert_equal "true", same, "an exact title+body match is the duplicate"
    assert_equal "false", body, "same title, different body → a DIFFERENT finding, keep it"
    assert_equal "false", title, "same body, different title → a DIFFERENT finding, keep it"
    assert_equal "false", near, "a near-miss is not a match — the guard never matches fuzzily"
  end

  # [integration] THE BUG: the same retro run twice refiled the same follow-up.
  # Run 1's REAL output is fed back as run 2's open inbox (rather than
  # re-deriving the title here, which would re-implement the helper under test),
  # so this is a true round-trip of what the CLI actually files.
  def test_integration_a_verbatim_identical_followup_files_once_not_twice
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)
      first = filed_findings(log)
      assert_equal 1, first.size, "the first run files the finding"

      inbox = first.map { |f| { "title" => f[:title], "body" => f[:body], "status" => "open" } }
      log2, setup2 = retro_triage_stub(dir, inbox: inbox)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup2)

      assert_empty filed_findings(log2), "a follow-up already open VERBATIM must not be filed again: #{out}"
      assert_includes out, "already open", "and the skip must SAY it skipped, not go quiet"
    end
  end

  # [integration] THE DIRECTION THAT MATTERS MOST — over-suppression loses real
  # findings silently. These two follow-ups share their first EIGHT words, so a
  # title-only (or fuzzy) guard would file one and swallow the other with no
  # trace. The body is what keeps them apart, and both must land.
  def test_integration_two_different_followups_both_file
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes",
                     "--followup", "fix the flaky board filter integration test in the hub suite",
                     "--followup", "fix the flaky board filter integration test in the engine suite"],
                    call: "retro", setup: setup)
      filed = filed_findings(log)

      assert_equal 1, filed.map { |f| f[:title] }.uniq.size,
                   "precondition: these follow-ups DO collide on title — that is the trap"
      assert_equal 2, filed.size, "two distinct follow-ups are two findings: #{out}"
      assert_equal 2, filed.map { |f| f[:body] }.uniq.size, "…and the bodies keep them distinct"
    end
  end

  # [integration] …including when one of them is ALREADY open: the open one is
  # skipped and the new one still lands. This is the guard being precise rather
  # than simply "file nothing when anything matches".
  def test_integration_a_new_followup_still_files_alongside_an_open_duplicate
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)
      inbox = filed_findings(log).map { |f| { "title" => f[:title], "body" => f[:body], "status" => "open" } }

      log2, setup2 = retro_triage_stub(dir, inbox: inbox)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake", "--followup", "adopt the crop guard harness"],
                    call: "retro", setup: setup2)
      filed = filed_findings(log2)

      assert_equal 1, filed.size, "exactly the NEW follow-up files: #{out}"
      assert_includes filed.first[:body], "crop guard", "and it is the new one, not the duplicate"
    end
  end

  # [integration] a repeat WITHIN one run files once — the pre-file read happens
  # before the loop, so the run must also count what it just filed.
  def test_integration_the_same_followup_repeated_in_one_run_files_once
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake", "--followup", "fix flake"],
                    call: "retro", setup: setup)

      assert_equal 1, filed_findings(log).size, "one run, one finding for the same text twice: #{out}"
    end
  end

  # [integration] the refuse-vs-warn call, pinned as BEHAVIOR: a follow-up too
  # short to identify itself WARNS and is still filed. Refusing would discard
  # text the operator just typed at the end of a ship, and the retro's own
  # contract is NON-BLOCKING.
  def test_integration_a_vague_followup_warns_but_is_still_filed
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)

      assert_match(/vague follow-up/i, out, "a follow-up too short to identify must be called out")
      assert_equal 1, filed_findings(log).size, "…and still filed — a warning never costs the operator their text"
      assert_includes out, "NON-BLOCKING", "the retro still ends non-blocking"
    end
  end

  # [integration] FAIL OPEN: if the inbox read fails, file anyway and say so. A
  # duplicate finding is cheaper than a lost one, and the retro must not start
  # failing a release over its own convenience read.
  def test_integration_an_unreadable_inbox_files_anyway_and_says_so
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir, list_ok: false)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)

      assert_equal 1, filed_findings(log).size, "an unreadable inbox must not silently drop the finding"
      assert_match(/could not read the open inbox/i, out, "…and the degraded check must be visible")
    end
  end

  def test_retro_record_ruby_passes_the_payload_shell_safe_not_raw_json
    # An adversarial payload: the exact metacharacters that broke heroku run.
    answers = { "worked" => ["fixed (a) bug && shipped"],
                "friction" => ['flaky "e2e" | pipe'], "followups" => [] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    # The raw JSON (the thing heroku's re-quoting eats) must NOT be interpolated.
    refute_includes out, %q("worked":), "the raw answers JSON must not ride into the runner command"
    refute_includes out, "&&", "no payload shell metacharacter rides raw into the command"
    refute_includes out, "(a)", "no payload parens ride raw into the command (remote bash syntax error)"
    refute_includes out, "| pipe", "no payload pipe rides raw into the command"
    # It rides as a url-safe Base64 blob the remote runner decodes, and still
    # renders through the retro model.
    assert_includes out, "Base64.urlsafe_decode64", "the payload is base64-decoded server-side"
    assert_includes out, "Release::Retro.render", "the snippet still renders via the retro model"
  end

  def test_retro_record_ruby_round_trips_quotes_parens_and_ampersands
    require "base64"
    require "json"
    answers = { "worked" => ['used "quotes" & (parens)', "shipped && done"],
                "friction" => ["bash $(danger) | pipe; rm -rf"],
                "followups" => ["file `backticks` and \\backslash" ] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, "the snippet embeds a url-safe Base64 literal: #{out}"
    assert_equal answers, JSON.parse(Base64.urlsafe_decode64(b64)),
                 "quotes/parens/&&/pipes/backticks/backslashes round-trip byte-for-byte through the payload encoding"
  end

  def test_retro_empty_answers_survive_the_runner_payload
    # The simplest repro: even all-empty answers were corrupted by the old raw
    # interpolation (quotes + leading chars eaten by heroku's re-quoting).
    answers = { "worked" => [], "friction" => [], "followups" => [] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, out
    assert_equal answers, JSON.parse(Base64.urlsafe_decode64(b64)),
                 "empty answers must survive intact (the JSON::ParserError repro)"
  end
end
