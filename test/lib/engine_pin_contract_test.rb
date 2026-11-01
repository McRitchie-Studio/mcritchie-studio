require "test_helper"

# Contract for the studio-engine pin. `~> 0.65` floors this app, but a pin string cannot
# speak for what RESOLVED, so these assert what this app runs: a loosened pin, a `path:`
# override or an unmigrated database fails HERE, not as a NoMethodError in a sign-in email.
# Properties, not lists: a hand-maintained column allowlist defends only against drift
# somebody thought of, and stayed green when studio-engine 0.46.0 shipped a `users`
# migration this app never installed. Two tests ask: has every migration the RESOLVED gem
# ships been installed here, and can the operator's Save land.
# History: task detect-engine-migration-content-drift.
class EnginePinContractTest < ActiveSupport::TestCase
  # Each entry is a feature this app relies on, with its version. 0.42: Studio::EmailSetting
  # and Studio::EmailPreviewTarget back /admin/emails (config.draw_admin_emails_routes);
  # UserMailer calls Studio::Banner.for(name:) and EmailCatalog.subject_for. 0.43:
  # EmailCatalog's .body, .cta_text, .cta_color, .cta_enabled?, called by
  # app/mailers/user_mailer.rb#magic_link on every send, and the studio_email_settings columns
  # behind them. The floor deliberately does NOT track the newest release: the migration test
  # below reads the RESOLVED gem, and a bump per release is a list by another name.
  # History: task detect-engine-migration-content-drift.
  MINIMUM = Gem::Version.new("0.43.0")

  # WHY FOUR TESTS: they fail on different days. The columns behind the mailer's methods live
  # in this app's db/schema.rb, so a downgrade leaves every schema-side test green while the
  # mailer is broken. The version test states the floor; the API test states what the floor is
  # FOR; the migration test catches a gem that moved FORWARD past this app's db/migrate; the
  # save test catches a schema that never caught up.
  # History: task detect-engine-migration-content-drift.

  # What app/mailers/user_mailer.rb reads off the catalog. Named as the methods
  # rather than as a version number, because this is the thing that actually
  # breaks: on 0.42.0 four of these five are missing — subject_for arrived in 0.42,
  # the other four in 0.43. MEASURED by resolving 0.42.0 and running this file.
  MAILER_COPY_API = %i[body cta_text cta_color cta_enabled? subject_for].freeze

  # The engine tables this app's mounted pages and mailers read.
  ENGINE_TABLES = %w[studio_links studio_email_settings studio_email_deliveries studio_enumerals].freeze

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)

    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(/admin/emails needs >= 0.42; the mailer's body and CTA copy needs >= 0.43)"
  end

  # SELF-FIRING, and that is the whole design. application.css imports the engine build first
  # and a local shim's :root comes after it, so equal specificity and later source order mean
  # THE SHIM WINS: a frozen private copy of the scale, with nothing failing. A ledger entry or
  # comment saying "delete at the bump" is a reminder, not a gate. Once the RESOLVED engine
  # defines the tiers, a local redefinition is drift. Silent while the pin is old; red the
  # instant it is not.
  # History: task delete-layer-scale-shims.
  test "no local shim redefines a layer tier the resolved engine already ships" do
    engine_css = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir)
                 .join("app/assets/tailwind/studio_engine/engine.css")
    # ASSERTED, not skipped. A `skip` here would opt this guard out silently and
    # cost a slot on the test-health ratchet — a test switched off keeps its name
    # and loses its coverage. The precondition is worth failing on anyway: this
    # app is pinned to an engine that ships the scale, so an engine that does NOT
    # means the pin walked backwards, and that is a defect in its own right.
    assert_includes engine_css.read, "--z-modal:",
                    "the resolved engine no longer ships the layer scale — the pin went backwards"

    app_css = Rails.root.join("app/assets/tailwind/application.css").read
                   .gsub(%r{/\*.*?\*/}m, " ") # comments EXPLAIN the tiers; scanning them would ban documenting this

    redefined = app_css.scan(/(--z-[a-z-]+):\s*-?\d+;/).flatten.uniq

    assert_empty redefined,
                 "the resolved engine ships the layer scale, so these local redefinitions now " \
                 "OUTRANK it (application.css imports the engine build ABOVE its own :root): " \
                 "#{redefined.join(', ')}. Delete them and read the engine's tiers."
  end

  test "the catalog answers the copy API this app's mailer calls" do
    missing = MAILER_COPY_API.reject { |method| Studio::EmailCatalog.respond_to?(method) }

    assert_empty missing,
                 "Studio::EmailCatalog is missing #{missing.join(", ")} — app/mailers/user_mailer.rb " \
                 "calls these on every send, and studio-engine #{Studio::VERSION} does not define them. " \
                 "This is what a resolved version below #{MINIMUM} looks like from inside the app."
  end

  # `studio_engine:install:migrations` COPIES the gem's migrations, renumbering each, so only
  # the name survives. It is a MANUAL step: a gem bump skips it and the app still boots and
  # passes. A pending-migration check cannot see this, since schema.rb stamps every version as
  # run. The failure is silent: Studio.record_ip_location! opens with `return false unless
  # user.respond_to?(:ip_locations)`. THIS IS THE NAME HALF OF THE CONTRACT, AND ONLY THE NAME
  # HALF: a migration whose BODY changed keeps its name.
  # `test/lib/engine_migration_content_test.rb` is the content half.
  # History: task detect-engine-migration-content-drift.
  test "every migration the resolved engine ships has been installed here" do
    assert_empty missing_engine_migrations,
                 "the resolved studio-engine (#{Studio::VERSION}) ships migrations this app never " \
                 "copied: #{missing_engine_migrations.join(", ")}. Run " \
                 "`bin/rails studio_engine:install:migrations && bin/rails db:migrate` — " \
                 "bumping the gem does NOT do it for you."
  end

  test "the engine tables this app's mounted pages read actually exist" do
    ENGINE_TABLES.each do |table|
      assert ActiveRecord::Base.connection.table_exists?(table),
             "#{table} is missing — run bin/rails studio_engine:install:migrations && db:migrate"
    end

    # Table-exists is not the same as the model working: the copy columns arrive
    # in three separate follow-up migrations, and a host that ran only the create
    # passes the check above and still 500s on /admin/emails.
    assert_nothing_raised { Studio::EmailSetting.limit(1).to_a }
  end

  # ASSERTS THE EFFECT, NOT THE SPELLINGS: columns are covered by USING them, so the test
  # extends itself when the engine's copy fields do. Each call is one /admin/emails makes on
  # Save, writing a column a follow-up engine migration adds; on a host whose schema trails
  # its gem, `record.body = ...` is a NoMethodError. Reading proves nothing: reads are
  # nil-safe and every writer short-circuits on `table_ready?` and returns nil. So round-trip
  # the values: a write that silently no-opped reads back as nil and fails here.
  # History: task detect-engine-migration-content-drift.
  test "the operator can actually save on /admin/emails" do
    assert_nothing_raised do
      Studio::EmailSetting.set_copy("magic_link", header: "Header the operator typed",
                                                  header_fallback: "Fallback header",
                                                  subtext: "Sub-text under the header",
                                                  subject: "Your link",
                                                  body: "Body copy the operator typed",
                                                  cta_text: "Sign in",
                                                  cta_color: "#B57EDC")
      Studio::EmailSetting.set_cta_enabled("magic_link", true)
    end

    assert_equal "Header the operator typed", Studio::EmailSetting.copy_for("magic_link", :header)
    assert_equal "Fallback header", Studio::EmailSetting.copy_for("magic_link", :header_fallback)
    assert_equal "Sub-text under the header", Studio::EmailSetting.copy_for("magic_link", :subtext)
    assert_equal "Your link", Studio::EmailSetting.copy_for("magic_link", :subject)
    assert_equal "Body copy the operator typed", Studio::EmailSetting.copy_for("magic_link", :body)
    assert_equal "Sign in", Studio::EmailSetting.copy_for("magic_link", :cta_text)
    assert_equal "#B57EDC", Studio::EmailSetting.copy_for("magic_link", :cta_color)
    assert_equal true, Studio::EmailSetting.cta_enabled_for("magic_link")
  end

  private

    # Engine migration names with no counterpart in this repo's db/migrate. Both sides reduce to
    # the bare name: `20260813220000_add_standard_user_profile_columns.rb` installs here as
    # `20260813223520_add_standard_user_profile_columns.studio_engine.rb`, so timestamp and
    # scope suffix are noise, and the suffix has been spelled both `.studio_engine` and
    # `.studio`. This also lets the app pass at all: four engine migrations were written HERE
    # first and remain native, un-suffixed files (create_studio_links and friends), which
    # `install:migrations` skips by name, so the host's copy must count as installed.
    # History: task detect-engine-migration-content-drift.
    def missing_engine_migrations
      @missing_engine_migrations ||= engine_migration_names - installed_migration_names
    end

    def engine_migration_names
      Studio::Engine.paths["db/migrate"].existent
                    .flat_map { |dir| Dir.children(dir) }
                    .grep(/\.rb\z/)
                    .map { |file| bare_migration_name(file) }
    end

    def installed_migration_names
      Dir.children(Rails.root.join("db/migrate"))
         .grep(/\.rb\z/)
         .map { |file| bare_migration_name(file) }
    end

    def bare_migration_name(file)
      file.sub(/\A\d+_/, "").sub(/\.[a-z_]+\.rb\z/, "").sub(/\.rb\z/, "")
    end
end
