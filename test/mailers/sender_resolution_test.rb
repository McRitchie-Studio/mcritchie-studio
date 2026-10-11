require "test_helper"

# Pins the hub's mail SENDER after the SES retirement (hub-drops-stale-ses-mentions).
#
# config/initializers/studio.rb used to pass `ses_from:` to
# Studio.mailer_from_for_transport. studio-engine 0.102.0 accepts that keyword and
# ignores it, so dropping it must not move the sender. These tests pin:
#   - the initializer calls the resolver with no ses_from (and no other override);
#   - the no-argument call resolves exactly as the old ses_from call did;
#   - RESEND_MAILER_FROM wins, and MAILER_FROM / MARKETING_MAILER_FROM are never read;
#   - the mail the hub actually builds carries that resolved sender.
class SenderResolutionTest < ActionMailer::TestCase
  DEFAULT_SENDER = "McRitchie Studio <team@mcritchie.studio>".freeze
  OLD_SES_FROM = "McRitchie Studio <team@mcritchie.studio>".freeze
  OLD_MARKETING_SES_FROM = "Alex McRitchie <alex@mcritchie.studio>".freeze
  INITIALIZER = Rails.root.join("config/initializers/studio.rb")

  ENVS = [
    {},
    { "RESEND_MAILER_FROM" => "Hub QA <qa@mcritchie.studio>" },
    { "RESEND_MAILER_FROM" => "  " },
    { "MAILER_FROM" => "Dead <dead@example.com>", "MARKETING_MAILER_FROM" => "Dead <mkt@example.com>" },
    { "RESEND_MARKETING_FROM" => "News <news@mcritchie.studio>" }
  ].freeze

  # --- unit ------------------------------------------------------------------

  test "the initializer resolves the sender with no ses_from argument" do
    code = INITIALIZER.read.lines.reject { |l| l.lstrip.start_with?("#") }.join
    assert_match(/config\.mailer_from = Studio\.mailer_from_for_transport$/, code)
    refute_match(/ses_from/, code)
    refute_match(/ses_from/, Rails.root.join("app/mailers/broadcast_mailer.rb").read)
  end

  test "the booted sender is the resolver's answer for this process" do
    assert_equal Studio.mailer_from_for_transport(env: ENV), Studio.mailer_from
  end

  test "dropping ses_from resolves exactly as the old call did, under every env" do
    ENVS.each do |env|
      assert_equal Studio.mailer_from_for_transport(env: env, ses_from: OLD_SES_FROM),
                   Studio.mailer_from_for_transport(env: env), "transactional, env=#{env.inspect}"
      assert_equal Studio.marketing_from_for_transport(env: env, ses_from: OLD_MARKETING_SES_FROM),
                   Studio.marketing_from_for_transport(env: env), "marketing, env=#{env.inspect}"
    end
  end

  test "RESEND_MAILER_FROM wins; blank or the dead variables fall to the default" do
    assert_equal DEFAULT_SENDER, Studio.mailer_from_for_transport(env: {})
    assert_equal "Hub QA <qa@mcritchie.studio>",
                 Studio.mailer_from_for_transport(env: { "RESEND_MAILER_FROM" => "Hub QA <qa@mcritchie.studio>" })
    assert_equal DEFAULT_SENDER, Studio.mailer_from_for_transport(env: { "RESEND_MAILER_FROM" => "  " })
    dead = { "MAILER_FROM" => "Dead <dead@example.com>", "MARKETING_MAILER_FROM" => "Dead <mkt@example.com>" }
    assert_equal DEFAULT_SENDER, Studio.mailer_from_for_transport(env: dead)
    assert_equal DEFAULT_SENDER, Studio.marketing_from_for_transport(env: dead)
  end

  # --- integration: the mail the hub builds ------------------------------------

  test "a sign-in email is sent from the resolved sender" do
    message = UserMailer.magic_link("sender-pin@example.com", "token-for-sender-pin")
    assert_equal Mail::Address.new(Studio.mailer_from).address, message.from.first
  end

  test "a broadcast is sent from the resolved marketing sender, ignoring MARKETING_MAILER_FROM" do
    saved = ENV["MARKETING_MAILER_FROM"]
    ENV["MARKETING_MAILER_FROM"] = "Dead <mkt@example.com>"
    broadcast = Broadcast.create!(subject: "Sender pin", template_key: "new_game_announcement",
                                  survivor_url: "https://example.com/sv", turf_totals_url: "https://example.com/tt")
    contact = Contact.create!(email: "sender-pin@example.com", first_name: "Pin")
    message = BroadcastMailer.campaign(broadcast, contact)
    assert_equal Mail::Address.new(Studio.marketing_from_for_transport(env: ENV)).address, message.from.first
    refute_equal "mkt@example.com", message.from.first
  ensure
    saved.nil? ? ENV.delete("MARKETING_MAILER_FROM") : ENV["MARKETING_MAILER_FROM"] = saved
  end
end
