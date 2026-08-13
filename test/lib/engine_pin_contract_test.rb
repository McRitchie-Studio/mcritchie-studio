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
# Modelled on turf-monster's test/lib/engine_pin_contract_test.rb, which is the
# reference shape. It carries one test that app does not — see WHY THREE, below.
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
  MINIMUM = Gem::Version.new("0.43.0")

  # WHY THREE TESTS, when the version assertion looks like it covers everything.
  #
  # They fail on different days, and the middle one exists because the third
  # CANNOT catch a walk-backwards on this app. The columns live in this app's own
  # checked-in db/schema.rb — resolving an older gem does not drop them — so a
  # downgrade leaves the schema test perfectly green while the mailer is already
  # broken. The version test states the floor; the API test states what the floor
  # is FOR, at the exact methods the mailer calls; the schema test catches the
  # other host failure entirely, a database that never ran the engine migrations.

  # What app/mailers/user_mailer.rb reads off the catalog. Named as the methods
  # rather than as a version number, because this is the thing that actually
  # breaks: on 0.42.0 four of these five are missing — subject_for arrived in 0.42,
  # the other four in 0.43. MEASURED by resolving 0.42.0 and running this file.
  MAILER_COPY_API = %i[body cta_text cta_color cta_enabled? subject_for].freeze

  # The engine tables this app's mounted pages and mailers read.
  ENGINE_TABLES = %w[studio_links studio_email_settings studio_email_deliveries studio_enumerals].freeze

  # The operator-editable copy behind /admin/emails. The first four arrived with
  # 0.42's add_copy / add_subject follow-ups; the last four with 0.43's
  # add_body_cta_footer. Named by the COLUMNS they create rather than by the
  # migration filenames — the "copy" migration adds no column called `copy`, and
  # asserting a filename's noun is how turf-monster's version of this first
  # failed.
  COPY_COLUMNS = %w[
    header header_fallback subtext subject
    body cta_text cta_color cta_enabled
  ].freeze

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

  test "the engine tables and the copy columns this app writes actually exist" do
    ENGINE_TABLES.each do |table|
      assert ActiveRecord::Base.connection.table_exists?(table),
             "#{table} is missing — run bin/rails studio_engine:install:migrations && db:migrate"
    end

    # Table-exists is not the same as the model working: the copy columns arrive
    # in three separate follow-up migrations, and a host that ran only the create
    # passes the check above and still 500s on /admin/emails.
    assert_nothing_raised { Studio::EmailSetting.limit(1).to_a }

    missing = COPY_COLUMNS - Studio::EmailSetting.column_names
    assert_empty missing,
                 "studio_email_settings is missing #{missing.join(", ")} — a follow-up engine " \
                 "migration did not run, so the copy an operator saves on /admin/emails has " \
                 "nowhere to be stored."
  end
end
