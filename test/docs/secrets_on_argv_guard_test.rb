# frozen_string_literal: true

# GUARD (secrets-never-on-argv-or-desk-env, 2026-10-24): a secret never appears on a
# command line.
#
# WHY. `ps` shows every process's arguments to every local process, and an agent's
# `pgrep -fl` or `ps` lands them in a transcript. The credential-rotation SOP
# itself told the operator to run `op item edit … <field>[concealed]=$NEW` and
# `heroku config:set <VAR>=$NEW`, and four runbooks did the same with
# placeholders, while admin-authority-rotation-plan-2026-10-06.md already forbade
# it. This scans the places an agent copies commands from (bin/, lib/tasks, docs/,
# RUNBOOK.md, README.md, .github/workflows) and fails on a new
# argv form. The fixes it points at: stdin (`printf '%s' "$V" | cmd`, `op item edit`
# reading item JSON on stdin), bin/heroku-secret-set for Heroku config, and a curl
# header read from a file or process substitution
# (`-H @<(printf 'Authorization: Bearer %s\n' "$TOKEN")`).
#
# WHAT COUNTS. One line at a time, backslash continuations joined:
#   config:set  — `heroku config:set NAME=…` where NAME looks secret, or the value
#                 is a secret-looking variable or an `op read`/`cat`/`pbpaste`.
#   op item     — an `op item edit|create` assignment of a concealed or password
#                 field, or of a secret-looking variable.
#   --token     — `--token|--api-key|--password|--secret …` taking a variable,
#                 `${{ secrets.X }}` or a command substitution.
#   header      — `Authorization: Bearer|token|Basic $VAR`, or any -H header whose
#                 name says secret, token, key or auth, taking a variable.
#   data        — a curl `-d`/`--data…` argument carrying a secret-looking variable.
#   op prefix   — `NAME=$(op read …) cmd`, the secret in the next command's env
#                 AND, in shells that echo it, its trace.
#   heroku run  — `heroku run --env "K=$V"` / `-e K=…` with a secret name or value.
#   curl user   — `curl -u user:$PASS` / `--user`, basic auth on argv.
#   shell -c    — `bash|sh|zsh -c "…$SECRET…"`: the outer shell expands a
#                 DOUBLE-quoted script into the child's argv. Single quotes are
#                 fine (the child reads its own environment).
#   ruby argv   — Ruby that builds argv from a secret: `system`/`exec`/`spawn`/
#                 `Open3.*`/`IO.popen`/`%x`/backticks with `#{secret}` interpolated,
#                 or a bare secret-named identifier as an argv element. The bare
#                 words `key`/`keys` are not secret in Ruby here (hash keys).
#                 app/ and lib/ Ruby is scanned for this form as well.
# Secret-looking: KEY, SECRET, TOKEN, PASSWORD, CREDENTIAL or PRIVATE in the name
# (and the rotation SOP's own $NEW, $OLD, $T), unless it names a public half
# (PUBKEY, PUBLIC_KEY, *_ID, *_URL, *_PATH, *_FILE, *_NAME).
#
# KNOWN FALSE NEGATIVES (pinned in FALSE_NEGATIVES below, so a fix moves a line
# from there to OFFENDERS rather than going unnoticed). One line at a time and
# by NAME, so the guard misses:
#   - a secret laundered through a neutral name (`v=$HEROKU_API_KEY; cmd "$v"`,
#     `x = token; system("curl #{x}")`);
#   - argv assembled across lines (a Ruby array built then splatted, a heredoc,
#     a multi-line `system(` call whose secret sits on a later line);
#   - `env K=$SECRET cmd`, `xargs`, `eval`, and any language other than shell,
#     Ruby and YAML workflows (Python, JS, Rust);
#   - a secret whose name says none of KEY/SECRET/TOKEN/PASSWORD/CREDENTIAL/
#     PRIVATE (`$DSN`, `$WEBHOOK`), and the public-half exemptions (`*_ID`,
#     `*_URL`) when the value is in fact secret (a URL with a password in it).
# Review still owns those; the guard keeps the common forms from coming back.
#
# NOT SCANNED: docs/agents/archive/, which is frozen verbatim history and says so
# at the top of every file there. Ruby code that builds an HTTP header in Net::HTTP
# is not argv and does not match.
#
# THE CONTROL. Every pattern is proved to fire on a known offender and to stay
# quiet on its argv-free rewrite, so a pattern that has gone blind fails here
# rather than passing the tree for nothing.
require "test_helper"

class SecretsOnArgvGuardTest < ActiveSupport::TestCase
  ROOT = Rails.root
  SCANNED = %w[bin lib/tasks docs RUNBOOK.md README.md .github/workflows].freeze
  EXCLUDED_PREFIXES = %w[docs/agents/archive/].freeze
  # The app's own Ruby is scanned too, for the Ruby argv forms (system, spawn,
  # Open3, popen, %x, backticks): a server shelling out with a secret in argv is
  # the same leak as a runbook line.
  RUBY_SCANNED = %w[app lib].freeze

  SECRET_NAME = /KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE|\A(?:NEW|OLD|T)\z/i
  PUBLIC_NAME = /PUB_?KEY|PUBLIC_?KEY|KEY_ID\z|_ID\z|_URL\z|_PATH\z|_FILE\z|_NAME\z/i
  VAR_REF = /\$\{?([A-Za-z_][A-Za-z0-9_]*)|\$\{\{\s*secrets\.([A-Za-z0-9_]+)/
  SECRET_SUBST = /\$\((?:op read|op item get|cat |pbpaste)/

  def self.secret_name?(name)
    !name.nil? && name.match?(SECRET_NAME) && !name.match?(PUBLIC_NAME)
  end

  def self.secret_ref?(value)
    return true if value.match?(SECRET_SUBST) || value.match?(/\$\{\{\s*secrets\./)

    value.scan(VAR_REF).flatten.compact.any? { |name| secret_name?(name) }
  end

  # The offences on one (continuation-joined) line, as short labels.
  def self.offences(line)
    found = []
    if line.include?("config:set")
      line.scan(/(<[A-Za-z_ ]+>|\b[A-Z][A-Z0-9_]*)=("[^"]*"|'[^']*'|\$\([^)]*\)|\S*)/).each do |name, value|
        found << "config:set #{name}" if secret_name?(name) || secret_ref?(value)
      end
    end
    if line.match?(/\bop item (?:edit|create)\b/)
      line.scan(/\]=("[^"]*"|\S*)/).flatten.each do |value|
        found << "op item assignment" if secret_ref?(value)
      end
      found << "op item concealed assignment" if line.match?(/\[(?:concealed|password)\]=/)
    end
    flag = /--(?:token|api-key|api_key|password|secret|auth-token|access-token)[ =]["']?(\$\{?[A-Za-z_]|\$\{\{|\$\()/
    found << "secret flag" if line.match?(flag)
    found << "auth header" if line.match?(/Authorization: (?:Bearer|token|Basic) \$(?:\{?[A-Za-z_]|\{\{|\()/)
    line.scan(/-H\s+["']([A-Za-z-]*(?:secret|token|key|auth)[A-Za-z-]*):\s*([^"']*)["']/i).each do |_header, value|
      found << "secret header" if value.match?(/\$(?:\{?[A-Za-z_]|\{\{|\()/)
    end
    line.scan(/(?:\s-d|--data(?:-binary|-raw|-urlencode)?)[ =](?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+))/).each do |parts|
      found << "secret in request data" if self.secret_ref?(parts.compact.first.to_s)
    end
    found << "op read prefix" if line.match?(/(?:\A|[\s;&|(])[A-Z][A-Z0-9_]*=["']?\$\((?:op read|op item get)[^)]*\)["']?[ \t]+[a-z.\/]/)
    found << "heroku run env" if heroku_run_env?(line)
    found << "curl user" if curl_user?(line)
    found << "shell -c interpolation" if shell_c_interpolation?(line)
    found << "ruby argv interpolation" if ruby_argv_interpolation?(line)
    found.uniq
  end

  # `heroku run --env "K=$V"` / `-e K=$V`: the one-off dyno's env is set from argv.
  def self.heroku_run_env?(line)
    return false unless line.match?(/\bheroku run\b/)

    line.scan(/(?:--env|\s-e)[ =](?:"([^"]*)"|'([^']*)'|(\S+))/).any? do |dq, sq, bare|
      value = dq || bare || sq.to_s
      # Single quotes stop the local shell from expanding the variable, but the
      # literal text still names it, and heroku sets it from that text: flag a
      # secret-looking assignment either way.
      value.scan(/([A-Z][A-Z0-9_]*)=([^;]*)/).any? { |name, val| secret_name?(name) || secret_ref?(val) }
    end
  end

  # `curl -u user:$PASS` / `--user`: basic-auth credentials on argv.
  def self.curl_user?(line)
    return false unless line.match?(/\bcurl\b/)

    line.scan(/(?:\s-u|--user)[ =]?(?:"([^"]*)"|'([^']*)'|(\S+))/).any? do |dq, _sq, bare|
      secret_ref?((dq || bare).to_s)
    end
  end

  # `bash -c "… $SECRET …"`: the DOUBLE-quoted script is expanded by the outer
  # shell, so the value lands in the child's argv. A single-quoted script reads
  # the variable inside the child, from its environment, and is not argv.
  def self.shell_c_interpolation?(line)
    line.scan(/\b(?:bash|sh|zsh)\s+(?:-[a-z]*\s+)*-[a-z]*c\s+"((?:[^"\\]|\\.)*)"/).flatten.any? { |script| secret_ref?(script) }
  end

  # A Ruby call that builds a child's argv. The backtick form counts only where a
  # backtick OPENS an expression (after `=`, `(`, `,`, `return` or at the start of
  # a statement), so prose in a string that quotes `code` in backticks is not a
  # shell-out.
  RUBY_ARGV_CALL = /\b(?:system|exec|spawn|Process\.spawn|IO\.popen|Open3\.\w+)\s*\(|%x[({\[|]|(?:\A\s*|[=(,]\s*|\breturn\s+)`/
  RUBY_ARRAY_CALL = /\A(?:system|exec|spawn|Process\.spawn|IO\.popen|Open3\.\w+)\s*\(/
  # A Ruby identifier names a secret on the same rule as a shell variable, except
  # the bare words `key`/`keys` (a hash key, a gate key), which mean nothing secret
  # in this tree's Ruby.
  def self.ruby_secret_name?(name)
    !%w[key keys].include?(name) && secret_name?(name)
  end

  # Ruby that BUILDS argv from a secret: `system("curl -H '…#{token}'")`,
  # `%x(… #{ENV["HEROKU_API_KEY"]})`, backticks, Open3/spawn/popen, and a bare
  # secret-named identifier passed as an argv element (`system("op", "x", password)`).
  def self.ruby_argv_interpolation?(line)
    call = line =~ RUBY_ARGV_CALL
    return false unless call

    tail = line[call..].lstrip.sub(/\A[=(,]\s*|\Areturn\s+/, "")
    interpolated = tail.scan(/\#\{([^}]*)\}/).flatten.any? do |expr|
      expr.scan(/[A-Za-z_][A-Za-z0-9_]*/).any? { |name| ruby_secret_name?(name) }
    end
    return true if interpolated
    return false unless tail.match?(RUBY_ARRAY_CALL)

    tail.scan(/,\s*@?([a-z_][a-z0-9_]*)\s*(?=[,)])/).flatten.any? { |name| ruby_secret_name?(name) }
  end

  def scanned_files
    Dir.chdir(ROOT) do
      ruby = `git ls-files -- #{RUBY_SCANNED.join(" ")}`.split("\n").select { |f| f.end_with?(".rb", ".rake") }
      (`git ls-files -- #{SCANNED.join(" ")}`.split("\n") + ruby).uniq
                                                             .reject { |f| EXCLUDED_PREFIXES.any? { |p| f.start_with?(p) } }
                                                             .select { |f| File.file?(f) }
    end
  end

  def offenders_in(text, label)
    hits = []
    # Join backslash continuations, keeping a line count so a hit names its first line.
    lineno = 0
    buffer = +""
    start = nil
    text.each_line do |raw|
      lineno += 1
      start ||= lineno
      line = raw.chomp
      if line.end_with?("\\")
        buffer << line.chomp("\\") << " "
        next
      end
      buffer << line
      found = self.class.offences(buffer)
      hits << "#{label}:#{start}: #{found.join(', ')}" unless found.empty?
      buffer = +""
      start = nil
    end
    hits
  end

  test "no command in bin/, lib/tasks, docs/, the runbook or .github/workflows puts a secret on argv" do
    files = scanned_files

    assert_operator files.length, :>=, 300, "only #{files.length} files scanned; the file list has gone blind"
    assert(files.any? { |f| f.end_with?("credential-rotation.md") }, "the rotation SOP is not in the scan")

    hits = files.flat_map do |file|
      text = File.read(File.join(ROOT, file), encoding: "UTF-8")
      text.valid_encoding? ? offenders_in(text, file) : []
    end

    assert hits.empty?, <<~MSG
      These lines put a secret on a command line, where `ps` shows it to every local
      process and an agent's process listing lands it in a transcript:

      #{hits.join("\n")}

      Pass it by stdin instead: `printf '%s' "$V" | cmd`, `op item edit` with item JSON
      on stdin, `… | bin/heroku-secret-set <app> <NAME>` for Heroku config, or a curl
      header from `-H @<(printf 'Authorization: Bearer %s\\n' "$TOKEN")`.
      The rule: docs/agents/modules/credentials.md.
    MSG
  end

  OFFENDERS = [
    'heroku config:set "<VAR>=$NEW" --app "$app"',
    "heroku config:set ANTHROPIC_API_KEY=<new_value> --app mcritchie-studio",
    'heroku config:set GOOGLE_SERVICE_ACCOUNT_JSON="$(cat "$KEYFILE")" --app x',
    "heroku config:set FOO=$(op read op://v/i/f) --app x",
    ': "${NEW:?}" && op item edit "<item>" --vault <vault> "<field>[concealed]=$NEW"',
    'op item create --vault v "credential[password]=hunter2"',
    'op item edit item "notes[text]=$API_SECRET"',
    'gh auth login --token "$GH_TOKEN"',
    "deploy --api-key ${{ secrets.HEROKU_API_KEY }}",
    'curl -s -H "Authorization: Bearer $CF_TOKEN" https://api.cloudflare.com/x',
    "curl -H \"Authorization: token ${{ secrets.GITHUB_TOKEN }}\" https://api.github.com",
    "HEROKU_API_KEY=$(op read 'op://v/heroku/credential') heroku apps",
    'curl -H "X-Edge-Secret: $EDGE_SECRET" https://origin.example',
    'curl -X POST "$BASE/api/v1/auth" -d "{\\"secret\\": \\"$SECRET\\"}"',
    # heroku run --env (N1)
    'heroku run --env "ROTATION_TOKEN=$NEW" --app turf-monster-qa -- bin/rails runner x',
    "heroku run -e API_SECRET=${API_SECRET} -a x -- true",
    'heroku run --env "FOO=$(op read op://v/i/f)" -a x -- true',
    # curl -u (N1)
    'curl -u "admin:$ADMIN_PASSWORD" https://example.test',
    "curl -sS --user api:$MAILGUN_API_KEY https://api.mailgun.net/v3",
    # bash -c interpolation (N1)
    'bash -c "curl -H \'Authorization: Bearer $CF_TOKEN\' https://x"',
    'sh -lc "heroku config:get X --app $APP | grep $SECRET"',
    # Ruby built argv (N1)
    'system("curl -sS -H \'Authorization: Bearer #{token}\' #{url}")',
    'out = %x(heroku apps --json #{ENV["HEROKU_API_KEY"]})',
    'Open3.capture3("op", "item", "edit", item, "password=#{new_password}")',
    'system("gh", "auth", "login", "--with-token", api_token)',
    'listing = `curl -u user:#{password} https://x`'
  ].freeze

  # Each a real blind spot (see KNOWN FALSE NEGATIVES above). Pinned QUIET so that
  # fixing one is a deliberate move into OFFENDERS, never a silent change.
  FALSE_NEGATIVES = [
    'v="$HEROKU_API_KEY"; curl -d "$v" https://x',
    'x = token; system("curl #{x}")',
    "env HEROKU_API_KEY=$NEW heroku apps",
    'curl -H "X-Hook: $WEBHOOK" https://x'
  ].freeze

  QUIET = [
    "printf '%s' \"$NEW\" | /Users/alex/projects/mcritchie-studio/bin/heroku-secret-set \"$app\" <VAR>",
    "op read 'op://v/anthropic/api key' | bin/heroku-secret-set mcritchie-studio ANTHROPIC_API_KEY",
    "heroku config:set EXPECTED_IDL_HASH=\"$(widened_set)\" --app \"$HEROKU_APP\"",
    "heroku config:set SOLANA_MULTISIG_SIGNERS=\"8K81,$QA_PUBKEY\" --app turf-monster-qa",
    "heroku config:set ENABLE_CDP_RAMP=true -a turf-monster-mainnet",
    'op item edit "<item>" --vault <vault> > /dev/null',
    "op item create --vault v - \"wallet-address[text]=$QA_PUBKEY\"",
    "curl -sS -H @<(printf 'Authorization: Bearer %s\\n' \"$CF_TOKEN\") https://api.cloudflare.com/x",
    'export GH_TOKEN="$(GH_APP_ITEM=github.mcritchie-admin bin/gh-token)"',
    'T=$(op read op://v/i/f) && [ -n "$T" ]',
    'request["Authorization"] = "Bearer #{token}"',
    "printf '{\"secret\": \"%s\"}' \"$SECRET\" | curl -sS -X POST \"$BASE/api/v1/auth\" --data-binary @-",
    "curl -H @<(printf 'X-Edge-Secret: %s\\n' \"$EDGE_SECRET\") https://origin.example",
    'curl -d "$3" -H "Content-Type: application/json" "$BASE$2"',
    # the argv-free rewrites of the N1 forms
    "printf 'ROTATION_REHEARSAL=1\\n' | heroku run --no-tty --app turf-monster-qa -- bin/rails runner x",
    "heroku run --env RAILS_ENV=production -a x -- true",
    "curl --netrc-file \"$NETRC\" https://example.test",
    "curl -u admin https://example.test",
    "bash -c 'curl -H @<(printf \"Authorization: Bearer %s\\n\" \"$CF_TOKEN\") https://x'",
    'bash -c "cd $ROOT && bin/rails test"',
    'system("bin/rails", "test", chdir: root)',
    'Open3.capture3({ "HEROKU_API_KEY" => token }, "heroku", "apps")',
    'Open3.capture3("op", "item", "edit", item, stdin_data: JSON.generate(fields))',
    'system(GATE_BIN, "open", "task", slug, key, out: File::NULL)',
    'say("run `bin/gh-auth-refresh` and this shell\'s GH_TOKEN is #{identity} sha256:#{digest(token)}")'
  ].freeze

  test "control: every pattern fires on a known offender and stays quiet on its argv-free rewrite" do
    OFFENDERS.each do |line|
      refute_empty self.class.offences(line), "the guard is blind to a known offender: #{line}"
    end
    QUIET.each do |line|
      assert_empty self.class.offences(line), "the guard flags an argv-free line: #{line} (#{self.class.offences(line).inspect})"
    end
  end

  test "control: the known false negatives are still quiet, so a fix to one is a deliberate move" do
    FALSE_NEGATIVES.each do |line|
      assert_empty self.class.offences(line),
                   "the guard now catches a listed false negative: move it to OFFENDERS and strike it from " \
                   "KNOWN FALSE NEGATIVES: #{line}"
    end
  end

  test "control: a continuation-joined offender is caught and named by its first line" do
    hits = offenders_in("echo start\nheroku config:set \\\n  \"<VAR>=$NEW\" --app x\n", "fixture.md")

    assert_equal 1, hits.length, hits.inspect
    assert hits.first.start_with?("fixture.md:2: config:set"), hits.inspect
  end
end
