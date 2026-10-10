# frozen_string_literal: true

# [unit] bin/ecosystem-build's Phase 4 env writer, EXECUTED against a synthetic
# `op` and a synthetic `heroku`.
#
# WHAT IT REPLACED. Until 2026-10-10 Phase 4 piped the PRODUCTION app's
# `heroku config` into each primary's .env through a deny list. A deny list
# keeps whatever it has not been told about, so the test that matters is not
# "is key X dropped" but "is a deployed app's config read at all". Here the
# synthetic `heroku` answers every `config` call with a sentinel and logs the
# call, and both the log and the files are checked.
#
# AND THE DEV PAIR ONLY. 1Password `r2.<app>` holds the production pair beside
# the dev pair. The synthetic `op` answers every field with a value that names
# the field, so a production field reaching a file is visible in the file, and
# a production field merely being READ is visible in the call log.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class EcosystemBuildLocalEnvTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")
  SENTINEL = "PRODUCTION-CONFIG-SENTINEL"

  def setup
    @dir = Dir.mktmpdir("ecosystem-build-local-env")
    @bin = File.join(@dir, "stub-bin")
    @projects = File.join(@dir, "projects")
    @log = File.join(@dir, "calls.log")
    FileUtils.mkdir_p(@bin)
    FileUtils.touch(@log)
    stub("heroku", <<~SH)
      #!/bin/bash
      echo "heroku $*" >> "#{@log}"
      case "$1" in
        auth:whoami) echo "agent@example.test" ;;
        config*) echo "RAILS_MASTER_KEY=#{SENTINEL}"; echo "RESEND_API_KEY=#{SENTINEL}" ;;
      esac
    SH
    # Every field answers with its own reference, so the file shows which field
    # each line was filled from.
    stub("op", <<~SH)
      #!/bin/bash
      echo "op $*" >> "#{@log}"
      case "$1" in
        vault) echo '[{"name":"studio-agents"}]' ;;
        read)
          case "$2" in
            *"/r2.no-such-item/"*) exit 1 ;;
            *) echo "value-of:$2" ;;
          esac ;;
        item) echo '{"fields":[{"label":"credential","value":"stub-heroku-key"}]}' ;;
      esac
    SH
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # ------------------------------------------------------------- .env -------

  def test_a_new_env_holds_only_local_development_values
    app_dir("mcritchie-studio")
    run_phase(apps: %w[mcritchie-studio])

    keys = keys_of(env("mcritchie-studio", ".env"))
    assert_equal %w[LOCAL_EMAIL_CAPTURE SECRET_KEY_BASE], keys.sort,
                 "an allow list: exactly what local development needs, nothing a deployed app holds"
    assert_equal "600", mode(env("mcritchie-studio", ".env"))
  end

  # THE REGRESSION. Put the `heroku config` restore back and both halves go red:
  # the call shows in the log, and the sentinel shows in the file.
  def test_no_deployed_apps_config_is_read_or_written
    app_dir("mcritchie-studio")
    out = run_phase(apps: %w[mcritchie-studio])

    refute_match(/^heroku config/, calls, "Phase 4 must not read a deployed app's config at all")
    written = Dir.glob(File.join(@projects, "**", ".env*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
    refute_empty written
    written.each { |file| refute_includes File.read(file), SENTINEL, "#{file} holds a production value" }
    refute_includes out, SENTINEL
  end

  def test_the_dev_secret_key_is_generated_not_fetched
    app_dir("mcritchie-studio")
    run_phase(apps: %w[mcritchie-studio])

    value = File.read(env("mcritchie-studio", ".env"))[/^SECRET_KEY_BASE=(.+)$/, 1]
    assert_match(/\A\h{128}\z/, value, "64 random bytes, hex: the shape bin/dev-secret-key generates")
  end

  def test_an_existing_env_is_never_edited
    app_dir("mcritchie-studio")
    File.write(env("mcritchie-studio", ".env"), "OPERATOR_ADDED=1\n")
    File.write(env("mcritchie-studio", ".env.development"), "OPERATOR_STORAGE=1\n")
    run_phase(apps: %w[mcritchie-studio])

    assert_equal "OPERATOR_ADDED=1\n", File.read(env("mcritchie-studio", ".env"))
    assert_equal "OPERATOR_STORAGE=1\n", File.read(env("mcritchie-studio", ".env.development"))
    refute_match(/^op read/, calls, "nothing to write, so no vault read is spent")
  end

  # What the writer left out has to be findable by the operator who needs it.
  def test_the_left_out_variables_are_named_with_their_source
    app_dir("mcritchie-studio")
    out = run_phase(apps: %w[mcritchie-studio])

    assert_match(/RAILS_MASTER_KEY/, out)
    assert_match(%r{config/master\.key}, out)
    assert_match(/AGENT_API_SECRET/, out)
    assert_match(/google\.studio\.local/, out)
  end

  # ------------------------------------------------- .env.development -------

  def test_storage_comes_from_the_r2_dev_pair
    app_dir("mcritchie-studio")
    run_phase(apps: %w[mcritchie-studio])

    file = File.read(env("mcritchie-studio", ".env.development"))
    assert_includes file, "ACTIVE_STORAGE_BACKEND=r2\n"
    assert_includes file, "STUDIO_S3_BACKEND=r2\n"
    assert_includes file, "R2_ENDPOINT=value-of:op://studio-agents/r2.mcritchie-studio/endpoint\n"
    assert_includes file, "R2_ACCESS_KEY_ID=value-of:op://studio-agents/r2.mcritchie-studio/access-key-id-dev\n"
    assert_includes file, "R2_SECRET_ACCESS_KEY=value-of:op://studio-agents/r2.mcritchie-studio/secret-access-key-dev\n"
    assert_includes file, "R2_PUBLIC_URL=https://assets-dev.mcritchie.studio\n"
    assert_equal "600", mode(env("mcritchie-studio", ".env.development"))
  end

  # The item holds the production and backup pairs too. Neither is so much as
  # read: a key that never enters the process cannot reach a file.
  def test_the_production_pair_is_never_read
    app_dir("mcritchie-studio")
    app_dir("turf-monster")
    run_phase(apps: %w[mcritchie-studio turf-monster])

    reads = calls.lines.grep(/^op read/)
    assert_equal 6, reads.size, "three fields an app, by name"
    assert_empty reads.grep(/-prod|-backup/), "only the dev fields and the endpoint"
    refute_match(/^op item get r2\./, calls, "a whole-item read would pull the production pair into the process")
  end

  def test_turf_gets_its_own_dev_public_url
    app_dir("turf-monster")
    run_phase(apps: %w[turf-monster])

    file = File.read(env("turf-monster", ".env.development"))
    assert_includes file, "R2_PUBLIC_URL=https://assets-dev.turfmonster.media\n"
    assert_includes file, "access-key-id-dev"
    refute_includes file, "r2.mcritchie-studio", "each app reads its own item"
  end

  # An app whose storage variable names this script does not know gets no file
  # and an instruction naming the item, never a guess.
  def test_an_unknown_app_gets_an_instruction_not_a_guess
    app_dir("moms-app")
    FileUtils.mkdir_p(File.join(@projects, "moms-app", "config"))
    File.write(File.join(@projects, "moms-app", "config", "storage.yml"), "r2:\n  access_key_id: <%= ENV[\"R2_ACCESS_KEY_ID\"] %>\n")
    out = run_phase(apps: %w[moms-app])

    refute File.exist?(env("moms-app", ".env.development"))
    assert_match(/r2\.moms-app/, out)
    assert_match(/access-key-id-dev/, out)
    refute_match(/^op read/, calls)
  end

  # Bucket pairs are opt-in. An app whose config reads no R2 key has no item to
  # be sent looking for, so the phase says nothing about storage for it.
  def test_an_app_with_no_r2_storage_is_not_pointed_at_an_item
    app_dir("cyvasse")
    out = run_phase(apps: %w[cyvasse])

    refute File.exist?(env("cyvasse", ".env.development"))
    refute_match(/r2\.cyvasse/, out)
    assert File.exist?(env("cyvasse", ".env")), "the app still gets its local .env"
  end

  def test_the_override_vault_is_the_one_read
    app_dir("mcritchie-studio")
    run_phase(apps: %w[mcritchie-studio], env: { "MCR_OP_VAULT_AGENT" => "studio-agents" })
    assert_match(%r{op read op://studio-agents/r2\.mcritchie-studio/endpoint}, calls)
  end

  # A field `op` cannot answer leaves NO file: half a credential file reads as
  # a configured backend and fails at the first upload instead.
  def test_an_unreadable_item_writes_no_storage_file
    app_dir("mcritchie-studio")
    out = sourced(<<~SH)
      r2_dev_public_url() { echo "https://assets-dev.example.test"; }
      write_r2_dev_env no-such-item "#{@projects}/mcritchie-studio/.env.development"
    SH

    refute File.exist?(env("mcritchie-studio", ".env.development"))
    assert_match(/not written/, out)
    assert_match(/access-key-id-dev/, out)
  end

  # ------------------------------------------------------- the source -------

  # AWS was retired on 2026-10-10: no IAM user, no key, no SES identity. A
  # rebuild that names an AWS or SES variable sends an operator to look for a
  # credential that does not exist.
  def test_the_script_names_no_aws_or_ses_variable
    hits = File.readlines(SCRIPT).each_with_index.select { |line, _| line.match?(/\b(?:AWS|SES)_[A-Z_]+/) }
    assert_empty hits.map { |line, i| "#{i + 1}: #{line.strip[0, 90]}" }
  end

  def test_the_script_never_reads_a_heroku_apps_config
    code = File.readlines(SCRIPT).reject { |line| line.lstrip.start_with?("#") }.join
    refute_match(/heroku\s+config/, code)
  end

  private

  def stub(name, body)
    path = File.join(@bin, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def app_dir(app)
    FileUtils.mkdir_p(File.join(@projects, app))
  end

  def env(app, name)
    File.join(@projects, app, name)
  end

  def keys_of(path)
    File.readlines(path).filter_map { |line| line[/\A([A-Z_][A-Z0-9_]*)=/, 1] }
  end

  def mode(path)
    format("%o", File.stat(path).mode & 0o777)
  end

  def calls
    File.read(@log)
  end

  def run_phase(apps:, env: {})
    sourced(<<~SH, env: env)
      RAILS_APPS=(#{apps.join(' ')})
      phase_secrets
    SH
  end

  # Source the script (which runs nothing when sourced), then drive it. The
  # stub bin is put FIRST on PATH after the source, because the script prepends
  # its own tool directories while loading. HOME is the temp dir, so the
  # operator's ~/.zprofile is neither read nor written.
  def sourced(body, env: {})
    script = <<~SH
      source "#{SCRIPT}" >/dev/null 2>&1
      export PATH="#{@bin}:$PATH"
      PROJECTS_DIR="#{@projects}"
      #{body}
    SH
    base = {
      "HOME" => @dir, "OP_SERVICE_ACCOUNT_TOKEN" => "stub-token", "HEROKU_API_KEY" => "stub-heroku-key",
      "PROJECTS_DIR" => @projects, "MCR_OP_VAULT_AGENT" => nil,
      # The metering shim logs every `op` call; keep the stub's out of the real ledger.
      "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log")
    }
    out, _status = Open3.capture2e(base.merge(env), "bash", "-c", script)
    out
  end
end
