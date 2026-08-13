# What /admin/emails can PREVIEW.
#
# The engine pre-registers this app's emails (Studio::EmailCatalog::STANDARD), so
# nothing here declares an email — the label, the artwork and the default copy are
# all inherited. Re-registering a key updates it in place and keeps every field
# that is not restated, so this attaches one thing: the preview builder.
#
# WHY IT IS WORTH A FILE. Without a `preview:` callable the manager shows "No
# preview is registered" and the operator edits body and CTA copy as raw
# templates — the field says "Hi {name}," and no screen anywhere shows "Hi Alex,".
# Copy that can only be checked by mailing yourself a sign-in link is copy that
# gets shipped unread, which is how the body paragraph came to open "Hi," under a
# banner greeting the recipient by name.
#
# The builder lives on UserMailer (see UserMailer.preview) rather than as a
# lambda body here, so it is reachable from a test. That test asserts the thing
# this file's existence risks: that the preview and the send render the SAME
# document. A preview that can disagree with the inbox is worse than no preview —
# it is a confident wrong answer, which is the failure mode this whole surface
# keeps producing.
#
# to_prepare, not a bare initializer body: the registry is re-seeded on each
# reload in development, and a one-shot registration would vanish at the first
# code change and take the preview with it.
Rails.application.config.to_prepare do
  Studio::EmailCatalog.register("magic_link", preview: -> { UserMailer.preview })
end
