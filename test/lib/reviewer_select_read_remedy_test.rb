# frozen_string_literal: true

# [integration] EVERY REMEDY bin/reviewer-select PRINTS ON A FAILED PR READ IS
# HARVESTED OFF ITS OWN STDERR AND RUN.
#
# THE DEFECT. Both of this tool's credential refusals printed, unconditionally:
#
#     eval "$(bin/gh-auth-refresh --export)"
#
# and no test asserted either string. The command is real and its whole stdout is
# `export GH_TOKEN='…'` (bin/gh-auth-refresh#export). But the read that had just
# failed is THIS process's — Task#derived_authors_probe → Github::TaskDerivation →
# Github::Client → Github::AppToken — and with App creds absent AppToken returns
# `ENV[FALLBACK_TOKEN_ENV]`, i.e. GITHUB_TOKEN. So the operator followed the
# printed line verbatim and got the byte-identical refusal, on the one refusal
# whose other exit is asserting something about somebody else's work.
#
# The house rule this broke is already written down, in bin/gh-auth-refresh's own
# header: EVERY REMEDY THIS COMMAND PRINTS MUST ROUND-TRIP — run it verbatim, in
# the lane that printed it. This file is that rule applied here.
#
# ── HOW THE REFUSALS ARE REACHED WITH NO NETWORK ─────────────────────────────
#
# `Github::TaskDerivation#parse!` raises Unreadable for a pr_url that is not a
# GitHub PR url BEFORE any HTTP is attempted (task_derivation.rb:161), so a task
# JSON naming such a url produces a genuine `unreadable` probe offline. Neither
# refusal was reachable from any CLI test before, because a script test cannot
# inject `derivation:` — it only gets to write the task JSON — and the test
# environment switches derivation off. DERIVE_FROM_GITHUB=1 arms the PATH, not a
# network call; see config/environments/test.rb.
#
# ── WHAT IS PROVEN HERE AND WHAT IS PROVEN NEXT DOOR ─────────────────────────
#
# Here: which remedy each refusal prints, that the paths resolve on disk, that the
# credential-free escape run verbatim SELECTS A PAIR, and that a non-credential
# fault gets NO credential remedy. The credential line's own round trip — run it,
# then read the variable back out of the shell — is measured in
# test/lib/github_read_remedy_test.rb, with the OLD remedy beside it as a control;
# it is not repeated here because this file would have to stub the broker anyway
# and the assertion belongs next to the composer.
#
#   ruby -Itest test/lib/reviewer_select_read_remedy_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../support/session_env"

class ReviewerSelectReadRemedyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin")
  SELECT = File.join(BIN, "reviewer-select")
  SLUG = "cli-sample"

  # A pr_url that CANNOT be parsed as a GitHub PR, so `authors` raises Unreadable
  # without a socket. The reason text carries the url, which is what lets the two
  # cases below differ only in the CAUSE the reason names.
  TRANSPORT_URL = "https://example.invalid/not-a-pull-request"

  # THE SAME OFFLINE DOOR, CARRYING A CREDENTIAL-SHAPED REASON. Stated plainly
  # because the input is synthetic and a reader deserves to know which part is real:
  # the pr_url is contrived so that the REASON STRING reaching the refusal matches
  # Release::GhFailure::CREDENTIAL_SIGNATURE, which is the only lever a test holding
  # nothing but a task JSON has. What that measures is the BRANCH SELECTION and the
  # text the credential branch prints — both real. It does not measure GitHub
  # returning a 401; the classifier's own spellings are covered in
  # test/models/release/gh_failure_test.rb.
  CREDENTIAL_URL = "stub://HTTP 401 Bad credentials"

  # A soul on the roster, substituted for the `<soul>` placeholder the refusal
  # prints. Deliberately NOT carl: he is the standing primary, so naming him as an
  # author exercises the seat-yielding path as well as the remedy, and a failure
  # there would be reported as a remedy failure.
  SUBSTITUTE_SOUL = "steffon"

  def setup
    @dir = Dir.mktmpdir("reviewer-select-read-remedy")
    @sandbox = TaskUsageSandboxEnv.child_env(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def task_file(pr_url, devops = {})
    path = File.join(@dir, "task-#{devops.hash.abs}-#{pr_url.hash.abs}.json")
    File.write(path, JSON.generate(
      "slug" => SLUG,
      "metadata" => { "devops" => { "shape" => "backend",
                                    "pr_urls" => { "mcritchie-studio" => pr_url } }.merge(devops) }
    ))
    path
  end

  # Runs the real script with derivation ARMED. stderr is kept — it is the refusal.
  def select(pr_url, *args, devops: {})
    env = SessionEnv.neutralized(
      @sandbox.merge("RAILS_ENV" => "test", "DERIVE_FROM_GITHUB" => "1",
                     "GH_TOKEN" => nil, "GITHUB_TOKEN" => nil)
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, SELECT, "--file", task_file(pr_url, devops),
                                      *args, chdir: ROOT)
    [out, err, status.exitstatus]
  end

  # THE REFUSAL, SLICED OUT OF stderr FROM ITS HEADLINE DOWN.
  #
  # stderr is NOT only the refusal. Under `bin/rails test` the child inherits bundler's
  # env and prints rubygems warnings ahead of anything the script says — the same noise
  # test/lib/reviewer_select_test.rb's header documents, which is why that file discards
  # stderr entirely. MEASURED: the first version of the block-shape assertion below read
  # stderr raw, passed under `ruby -Itest`, and failed under `bin/fast-check` on
  # "already initialized constant Gem::Platform::JAVA" — a test that depended on which
  # runner invoked it. The refusal starts at its headline, so say that rather than
  # trusting the stream to be clean.
  def refusal(stderr)
    lines = stderr.lines
    start = lines.index { |line| line.start_with?("reviewer-select REFUSED") }

    refute_nil start, "no refusal headline in stderr at all, so nothing below is measured:\n#{stderr}"

    lines[start..].join
  end

  # EVERY RUNNABLE COMMAND IN THE REFUSAL, found the way a copying operator finds
  # one: a line that IS an invocation. The scripts are printed ABSOLUTE now, so the
  # extractor keys on "the line starts with a path under this repo's bin, or with an
  # `export`/`eval` wrapper around one" rather than on a bare `bin/` prefix.
  def printed_remedies(stderr)
    stderr.lines.filter_map do |line|
      text = line.strip
      next if text.start_with?("(")          # a parenthetical aside is prose
      next unless text.match?(%r{(?:\A|\$\()#{Regexp.escape(BIN)}/|\Aexport\s+[A-Z_]+="\$\(})

      text.sub(/\s{2,}#.*\z/, "").strip      # drop a trailing `  # comment` column
    end
  end

  # --- the refusals print the remedy that fits the CAUSE ------------------------

  def test_the_credential_refusal_names_the_variable_the_read_consumes
    _out, err, code = select(CREDENTIAL_URL, "--builder", "none", "--dry")

    assert_equal 2, code, "an unverified `none` must refuse:\n#{err}"
    assert_match(/`none` IS UNVERIFIED/, err)
    assert_match(/export GITHUB_TOKEN="\$\(#{Regexp.escape(File.join(BIN, "gh-token"))}\)"/, err,
                 "the credential remedy must refresh GITHUB_TOKEN — what Github::AppToken reads — " \
                 "by absolute path:\n#{err}")
    refute_match(/gh-auth-refresh --export\)"\s*\z/, err,
                 "the OLD remedy must not still be handed over as the fix")
  end

  def test_a_non_credential_fault_is_given_no_credential_remedy
    # THE OTHER HALF OF THE SAME DEFECT, and the standard bin/dor-check already
    # holds: test/lib/dor_check_test.rb#test_gh_or_network_error_refuses_without_naming_a_credential asserts there is no gh-auth-refresh on
    # a transport fault. `unreadable` covers a 401, a rate limit, a 5xx, a dead
    # network and a pr_url that names no PR; printing "refresh the credential" for
    # the last four is a false causal claim, and an operator who pastes it loops.
    _out, err, code = select(TRANSPORT_URL, "--builder", "none", "--dry")

    assert_equal 2, code, "an unverified `none` must refuse:\n#{err}"
    refute_match(/export GITHUB_TOKEN=/, err,
                 "there is no credential to refresh for a pr_url that names no PR:\n#{err}")
    refute_match(/gh-auth-refresh/, err, "nor any other credential remedy")
    assert_match(/NOT a credential fault/, err, "and the refusal must SAY so rather than going quiet")
  end

  def test_the_two_causes_really_do_take_different_branches
    # THE CONTROL FOR THE TWO CASES ABOVE. Both drive the same refusal through the
    # same offline door; if the classifier were inert (always-credential or
    # never-credential) one of them would still pass. Asserting they DIFFER is what
    # makes the pair mean something.
    _o1, credential, = select(CREDENTIAL_URL, "--builder", "none", "--dry")
    _o2, transport, = select(TRANSPORT_URL, "--builder", "none", "--dry")

    assert_includes credential, "export GITHUB_TOKEN="
    refute_includes transport, "export GITHUB_TOKEN="
    refute_equal credential.sub(CREDENTIAL_URL, ""), transport.sub(TRANSPORT_URL, ""),
                 "the two refusals differ only in the url, so the cause is not being read at all"
  end

  def test_the_authors_unknown_refusal_takes_the_same_remedy
    # The SECOND site, reached from the other door: no assertion at all, blank
    # built_by, and a PR that could not be read. It used to report "the PR's commits
    # were READ and name no soul" — a false sentence upstream of a false assertion.
    _out, err, code = select(CREDENTIAL_URL, "--dry")

    assert_equal 2, code, "an unreadable author set must refuse:\n#{err}"
    assert_match(/AUTHORS ARE UNKNOWN/, err)
    assert_match(/This is NOT "the PR has no author"/, err)
    assert_match(/export GITHUB_TOKEN="\$\(#{Regexp.escape(File.join(BIN, "gh-token"))}\)"/, err, err)
  end

  # --- the reason is one line --------------------------------------------------

  def test_the_quoted_reason_never_breaks_the_refusal_block
    # The reason is a GitHub API error whose body is multi-line JSON. Interpolated raw
    # it splits the indented block open and every single-line grep over the refusal
    # loses the half it was looking for.
    #
    # ASSERTED ON THE BLOCK'S SHAPE, NOT ON A PHRASE, and the first spelling of this
    # case is why. It looked for the phrase "not a GitHub PR url" on one line and
    # asserted both halves of the payload were on it — and it stayed GREEN with the
    # squeeze removed, because Ruby's `inspect` re-escapes the newline inside the
    # exception message, so the phrase and both halves rode the SAME line anyway. The
    # assertion was measuring the escaped copy while the defect was in the raw
    # interpolation two lines above it. Measured: unsqueezed, the block really prints
    #
    #     the commits on stub://HTTP 401
    #   {"message": "Bad credentials"} could not be read (not a GitHub PR url: "…")
    #
    # so the observable defect is a body line starting at COLUMN ZERO. A refusal block
    # has exactly one unindented line — its headline — and that is what is asserted.
    _out, err, = select("stub://HTTP 401\n{\"message\": \"Bad credentials\"}", "--builder", "none", "--dry")

    body = refusal(err).lines.reject { |line| line.strip.empty? }

    refute_empty body, "nothing was printed, so this proves nothing:\n#{err}"
    assert_match(/\Areviewer-select REFUSED/, body.first,
                 "the headline is the one line that starts at column zero:\n#{err}")

    flush_left = body.drop(1).reject { |line| line.start_with?(" ") }

    assert_empty flush_left.map(&:chomp),
                 "a raw multi-line reason broke the refusal block open — these body lines start " \
                 "at column zero, so an operator's single-line grep over the refusal loses " \
                 "whichever half it was not looking at:\n#{err}"
  end

  # --- every printed remedy is RUN ---------------------------------------------

  # Remedies that are NOT executed here, each with the reason. Keyed on a regex over
  # the LINE'S OWN TEXT, never a line number, and every entry is asserted below to
  # still match something a refusal really prints — so an entry cannot rot into an
  # excuse for a remedy that quietly disappeared.
  NOT_EXECUTED = [
    { match: %r{/bin/task move \S+ building --actor}, why:
      "a BOARD WRITE against the live production board. Running it would move a real task's " \
      "stage from a test, and `bin/task move` is covered by test/lib/task_cli_test.rb against " \
      "a stubbed board. The assertion here is that the line RESOLVES, not that it fires." },
    { match: /\Aexport GITHUB_TOKEN="\$\(/, why:
      "executed verbatim in test/lib/github_read_remedy_test.rb, which stubs bin/gh-token's " \
      "cache into a tmpdir and then reads the variable back out of the shell — including the " \
      "OLD remedy as a control. Running it here would need the same stub with nothing added." },
    { match: /--builder none\b/, why:
      "the assertion under test. Re-running the refusing command is what an operator must NOT " \
      "be told to do, and the refusal lists it only to say what it asserts." }
  ].freeze

  def test_every_printed_remedy_resolves_on_disk_and_the_executable_one_selects_a_pair
    [[CREDENTIAL_URL, %w[--builder none --dry]],
     [CREDENTIAL_URL, %w[--dry]],
     [TRANSPORT_URL, %w[--builder none --dry]]].each do |(url, args)|
      _out, err, = select(url, *args)
      remedies = printed_remedies(err)

      refute_empty remedies, "#{url} #{args.join(" ")}: no runnable remedy was printed, so this " \
                             "guard proves nothing:\n#{err}"

      remedies.each do |remedy|
        script = remedy[/\$\((.+?)\)/, 1] || remedy.split(/\s+/).first

        # ASKS THE DISK. An absolute path CONTAINS the bare form, so a substring
        # assertion here would pass on the exact defect it is written for.
        assert_equal File.expand_path(script), script,
                     "#{remedy.inspect} hands back a command a satellite or gem desk cannot run"
        assert File.executable?(script), "#{script.inspect} is not an executable on this disk"

        next if NOT_EXECUTED.any? { |entry| remedy.match?(entry[:match]) }

        assert_remedy_selects_a_pair(url, remedy)
      end
    end
  end

  # RUN IT VERBATIM, with only the `<soul>` placeholder filled the way the refusal
  # tells the reader to fill it — and assert the act the remedy PROMISES: a pair.
  def assert_remedy_selects_a_pair(url, remedy)
    filled = remedy.sub("<soul>[,<soul>]", SUBSTITUTE_SOUL).sub("<soul>", SUBSTITUTE_SOUL)

    refute_includes filled, "<", "a placeholder survived the substitution: #{filled}"

    # The refusal cannot know the task came from a file, so its line names the slug.
    # Point the re-run at the same offline payload rather than the live board; the
    # ARGUMENTS the operator would paste are otherwise untouched.
    argv = filled.split(/\s+/)
    argv = argv.each_with_index.flat_map { |arg, i| i == 1 ? ["--file", task_file(url), "--dry"] : [arg] }

    env = SessionEnv.neutralized(
      @sandbox.merge("RAILS_ENV" => "test", "DERIVE_FROM_GITHUB" => "1",
                     "GH_TOKEN" => nil, "GITHUB_TOKEN" => nil)
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, *argv, chdir: ROOT)

    assert_equal 0, status.exitstatus,
                 "following the printed remedy verbatim did NOT clear the refusal:\n#{remedy}\n#{err}"
    assert_match(/primary/i, out, "and it must actually print a pair:\n#{out}")
    refute_match(/REFUSED/, err, "the refusal must be gone, not merely re-worded:\n#{err}")
  end

  # --- the floors: what stops a green sweep from proving nothing ----------------

  def test_the_remedy_extractor_finds_commands_and_only_commands
    _out, err, = select(CREDENTIAL_URL, "--builder", "none", "--dry")
    found = printed_remedies(err)

    assert_operator found.size, :>=, 2,
                    "the credential refusal prints a credential remedy AND a credential-free " \
                    "escape; #{found.size} means the extractor stopped seeing one:\n#{err}"
    refute_empty err.lines.reject { |line| found.include?(line.strip) },
                 "the refusal is mostly prose, which must NOT be mistaken for a command"
    assert_empty printed_remedies("  An unreadable PR is NOT an authorless PR, and bin/task knows it\n"),
                 "a sentence that merely NAMES a script is not a remedy"
  end

  def test_every_not_executed_entry_still_matches_a_remedy_a_refusal_prints
    # A registry of exemptions is a registry that rots. Each entry must match a line
    # some refusal really prints, or it is an excuse for a remedy that vanished.
    printed = [[CREDENTIAL_URL, %w[--builder none --dry]],
               [CREDENTIAL_URL, %w[--dry]]].flat_map do |(url, args)|
      _out, err, = select(url, *args)
      printed_remedies(err)
    end

    refute_empty printed, "nothing was harvested, so every claim below is vacuous"

    NOT_EXECUTED.each do |entry|
      assert printed.any? { |remedy| remedy.match?(entry[:match]) },
             "no refusal prints a remedy matching #{entry[:match].inspect} any more — delete the " \
             "entry rather than letting it excuse a remedy that is gone.\nharvested:\n#{printed.join("\n")}"
    end
  end
end
