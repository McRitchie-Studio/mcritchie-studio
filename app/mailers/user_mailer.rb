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

    # The NAME, from an EXISTING account only. A magic link may be the first
    # thing a stranger ever receives from us — addressing them by a name we do
    # not have would be worse than not addressing them at all.
    #
    # The name is all this mailer supplies. What the banner SAYS about it — the
    # greeting, the sub-text, whether it uses the name at all — is the
    # operator's, editable on /admin/emails. Passing a finished header here
    # would leave those fields accepting edits that never reach an inbox.
    @banner = Studio::Banner.for(:magic_link, name: name_for(email))
    @banner_alt = [@banner&.header, "your #{@app_name} sign-in link"].compact.join(" — ")

    # Kept as the floor: if no layered artwork is registered, the layout falls
    # back to the flat <img> exactly as it did before.
    @banner_url = Studio::EmailCatalog.resolved_url(:magic_link)

    # THE COPY BELOW THE BANNER, on the same terms as the banner's words. This
    # class SHADOWS the engine's UserMailer, so the engine wiring these up in
    # 0.43 did nothing here — but the engine's VIEW still renders (there is no
    # app/views/user_mailer/ in this app), and it falls back to
    # EmailCatalog.body(:magic_link) with NO name. The result was one email
    # disagreeing with itself: the banner greeted "Welcome Alexander!" while the
    # paragraph under it opened "Hi,".
    #
    # Nothing raised and no placeholder leaked — the registry tidies "{name}"
    # out of copy it cannot fill — which is exactly why this needed measuring
    # rather than reading. An operator writing "Hi {name}," on /admin/emails saw
    # it silently flatten for every recipient we could actually have named.
    @body      = Studio::EmailCatalog.body(:magic_link, name: name_for(email))
    @cta_text  = Studio::EmailCatalog.cta_text(:magic_link, name: name_for(email)) if Studio::EmailCatalog.cta_enabled?(:magic_link)
    @cta_color = Studio::EmailCatalog.cta_color(:magic_link)

    # The operator's subject when one is saved on /admin/emails, else the
    # hard-coded line. Same division as the banner: the mailer supplies the
    # recipient, the operator supplies the words.
    # The name goes to the SUBJECT too, not just the banner — otherwise a
    # subject template containing {name} reaches the inbox with the raw token in
    # it, which is the most visible way this can fail.
    subject = Studio::EmailCatalog.subject_for(:magic_link, name: name_for(email)) ||
              "Your #{@app_name} sign-in link"
    mail(to: email, subject: subject)
  end

  private

  # The recipient's name when we already hold an account for them, else nil —
  # which is what makes the banner fall back to its name-free header.
  #
  # RESCUED like the engine's recipient_name this class overrides. The greeting
  # is a nicety; the link is how someone gets back into their account, so a
  # transient lookup failure must cost the name and never the send.
  def name_for(email)
    User.find_by(email: email.to_s.strip.downcase)&.display_name.presence
  rescue StandardError
    nil
  end
end
