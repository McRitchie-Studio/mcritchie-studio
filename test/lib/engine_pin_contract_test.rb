require "test_helper"

# Contract for the studio-engine pin.
#
# The Gemfile pin is `~> 0.43` — that is `>= 0.43, < 1.0`, so it DOES floor this
# app, and a plain `bundle update` cannot walk the resolved version backwards.
# What a pin string cannot do is speak for what RESOLVED; reading one as the
# other is how "turf is on 0.31" got believed while that app's lockfile said
# 0.39. These assert what this app actually runs, so a loosened pin, a `path:`
# override, or an unmigrated database fails HERE instead of as a NoMethodError
# inside a sign-in email that nobody is watching.
#
# WHAT THIS FILE GOT WRONG, and why it now asserts properties instead of lists.
#
# On 2026-08-13 studio-engine 0.46.0 shipped the first engine migration ever to
# touch the `users` table, and this app never installed it. Every test below was
# green throughout: the version floor was satisfied, the mailer API answered,
# the engine tables existed, and the hand-written column allowlist named only
# `studio_email_settings` columns, so a `users` migration was invisible to it.
# The drift was caught by mcritchie-industries, whose copy of this file asks the
# GENERIC question instead — and failed. Same filename, same intent, opposite
# outcome.
#
# So the allowlist is gone. A hand-maintained list of names only ever defends
# against the drift somebody already thought of, which is the third incident of
# that exact shape on this board. The two tests that replaced it ask what is
# actually true: has every migration the RESOLVED gem ships been installed here,
# and can the operator's Save actually land.
class EnginePinContractTest < ActiveSupport::TestCase
  # Each entry is a feature this app relies on, with the version that introduced
  # it, so the floor is justified rather than aspirational.
  #
  #   0.42 — Studio::EmailSetting and Studio::EmailPreviewTarget back
  #          /admin/emails, a page this app mounts from the engine
  #          (config.draw_admin_emails_routes), and UserMailer calls
  #          Studio::Banner.for(name:) plus EmailCatalog.subject_for.
  #   0.43 — EmailCatalog grows the email BELOW the banner: .body, .cta_text,
  #          .cta_color and .cta_enabled?, which app/mailers/user_mailer.rb:44-46
  #          calls on every magic-link send, and the studio_email_settings
  #          columns behind them.
  #
  # The floor deliberately does NOT track the newest release. Migrations that
  # arrive after it are covered by the migration test below, which reads the
  # RESOLVED gem — a floor bump per release would be a list by another name.
  MINIMUM = Gem::Version.new("0.43.0")

  # WHY FOUR TESTS, when the version assertion looks like it covers everything.
  #
  # They fail on different days, and none of the others can stand in for the
  # version test. The mailer's methods live in the gem, but the columns behind
  # them live in this app's own checked-in db/schema.rb — so resolving an OLDER
  # gem does not drop them, and a downgrade leaves every schema-side test
  # perfectly green while the mailer is already broken. The version test states
  # the floor; the API test states what the floor is FOR, at the exact methods
  # the mailer calls; the migration test catches a gem that moved FORWARD past
  # this app's db/migrate; the save test catches a schema that never caught up.

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

  test "the catalog answers the copy API this app's mailer calls" do
    missing = MAILER_COPY_API.reject { |method| Studio::EmailCatalog.respond_to?(method) }

    assert_empty missing,
                 "Studio::EmailCatalog is missing #{missing.join(", ")} — app/mailers/user_mailer.rb " \
                 "calls these on every send, and studio-engine #{Studio::VERSION} does not define them. " \
                 "This is what a resolved version below #{MINIMUM} looks like from inside the app."
  end

  # THE TEST THAT WOULD HAVE CAUGHT THE 0.46 DRIFT.
  #
  # `studio_engine:install:migrations` COPIES the gem's migrations into this
  # repo, renumbering each one to the install time — so the versions never match
  # and only the name survives the copy. That copy is a MANUAL step: bumping the
  # gem does not perform it, and an app that skips it boots perfectly, passes
  # its suite, and is missing columns its gem's own code writes to.
  #
  # Comparing the gem's migration NAMES against this repo's is therefore the
  # honest question. A pending-migration check cannot answer it: the test schema
  # is loaded from schema.rb, which stamps every version as run, so a migration
  # that was never copied is not "pending" — it is invisible.
  #
  # The failure this guards is silent by construction. Studio.record_ip_location!
  # opens with `return false unless user.respond_to?(:ip_locations)`, so on a
  # drifted app it returns false forever: no raise, no ErrorLog, no Sentry.
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

  # ASSERTS THE EFFECT, NOT THE SPELLINGS.
  #
  # This replaces a COPY_COLUMNS allowlist that checked `column_names` against a
  # hand-written list. Every column that list named is still covered — the eight
  # of them are exactly what the two writes below set — but they are covered by
  # USING them, so the test extends itself when the engine's copy fields do.
  #
  # Each call here is one /admin/emails makes when the operator presses Save,
  # and each writes a column a follow-up engine migration adds. On a host whose
  # schema trails its gem, `record.body = ...` is a NoMethodError, which is
  # precisely the 500 that would be waiting in production. Reading proves
  # nothing on its own: reads are nil-safe by design and stay quiet on a
  # half-installed schema, and every writer short-circuits on `table_ready?` and
  # returns nil. So round-trip the values — a write that silently no-opped reads
  # back as nil and fails here.
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

    # Engine migration names that have no counterpart in this repo's db/migrate.
    #
    # Both sides are reduced to the bare name: the gem's
    # `20260813220000_add_standard_user_profile_columns.rb` installs here as
    # `20260813223520_add_standard_user_profile_columns.studio_engine.rb`, so the
    # timestamp and the `.studio_engine` / `.studio` scope suffix are both noise.
    # The suffix has been spelled BOTH ways across these apps' histories, which
    # is why it is stripped rather than matched.
    #
    # Stripping to the bare name is also what lets this app pass at all: four of
    # the engine's migrations were written HERE first and are still carried as
    # native, un-suffixed files (create_studio_links and friends).
    # `install:migrations` skips those by name, so the host's own copy must count
    # as installed — which it does, because both sides reduce identically.
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
