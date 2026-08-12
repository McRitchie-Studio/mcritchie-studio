# McRitchie Studio's UserMailer. Overrides the engine's (a host-defined
# UserMailer wins) for one reason: the banner is composed per-recipient here,
# so the picture at the top of a sign-in email can greet the person by name.
#
# Everything else about the email — the shell, the button, the copy — stays the
# engine's.
class UserMailer < ApplicationMailer
  include Studio::MagicLinkIssuing

  layout "branded_mailer"

  def magic_link(email, token)
    @app_name  = Studio.app_name
    @email     = email
    @magic_url = magic_link_url_for(token)

    # The greeting is derived from an EXISTING account only. A magic link may be
    # the first thing a stranger ever receives from us — addressing them by a
    # name we do not have would be worse than not addressing them at all.
    @greeting = greeting_for(email)
    @banner_alt = [@greeting, "your #{@app_name} sign-in link"].compact.join(" — ")

    # Composed banner first, static catalogue banner if anything at all went
    # wrong composing it. EmailBanner returns nil rather than raising precisely
    # so that a font, a bucket or a background cannot stop a sign-in link.
    @banner_url = EmailBanner.url_for(header: @greeting, subtext: "your sign-in link is below") ||
                  Studio::EmailCatalog.resolved_url(:magic_link)

    mail(to: email, subject: "Your #{@app_name} sign-in link")
  end

  private

  # "Welcome Mason!" for someone we know, "Your Magic Link" for someone we do
  # not. Both are real headers; neither guesses.
  def greeting_for(email)
    user = User.find_by(email: email.to_s.strip.downcase)
    name = user&.display_name.presence
    name ? "Welcome #{name.split.first}!" : "Your Magic Link"
  end
end
