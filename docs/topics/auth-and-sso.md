# Auth & SSO

> **When to read this:** Touching the engine integration, SSO flow, login/signup views, or any cross-app authentication concern.

## Studio Engine Integration

Shared code lives in the [studio engine](https://github.com/amcritchie/studio-engine). This app includes it via `config/initializers/studio.rb`:

```ruby
Studio.configure do |config|
  config.app_name = "McRitchie Studio"
  config.session_key = :studio_user_id
  config.sso_logo = "/studio-logo.svg"
  config.welcome_message = ->(user) { "Welcome to McRitchie Studio, #{user.display_name}!" }
  config.auth_methods = %i[magic_link google wallet]
  config.registration_params = [:name, :email]
  config.magic_link_token_name = "magic_link_mcritchie_v1"
  config.configure_sso_user = ->(user) { user.role = "viewer" }
end
```

**From the engine:** `Studio::ErrorHandling` concern (in ApplicationController), `ErrorLog` model, `Sluggable` concern, passwordless magic-link primitives, auth controllers (sessions, registrations, omniauth_callbacks, error_logs), error log views, generic auth views, local email capture, theme routes, and shared email delivery primitives.

**Overridden locally:** `sessions/new.html.erb` and `registrations/new.html.erb` render the same unified `/signin` card with magic link, Google, and Solana wallet options.

**Routes:** The app defines canonical `GET /signin` first. Legacy `GET /login` and `GET /signup` redirect there, then `Studio.routes(self)` draws the compatibility auth routes, magic-link request/confirm/consume routes, `/logout`, `/sso_continue`, `/sso_login`, OAuth callbacks, `/error_logs`, local email capture, and `/admin/theme`.

## SSO Hub Role

This app is the central auth hub for apps that opt into Studio SSO. On sign-in,
`set_app_session` stores `sso_*` fields (including `sso_logo`) in the shared
session. The generic satellite pattern points authenticated navbar links at
`/sso_login` on each satellite app; SSO-created users on satellite apps get
`role = "viewer"` via `configure_sso_user`. Requires compatible session secrets.

Current caveat: Turf Monster intentionally disables cross-app SSO and 404s
`/sso_login` / `/sso_continue` while the money-app cookie stays isolated on
`turfmonster.media`. Use direct magic-link login for Turf Monster smoke
tests until SSO is redesigned and re-enabled.

The McRitchie Studio sign-in page does NOT show "Continue as" because the hub is a
sender, not a receiver.

**Updating:** After changes to the studio repo, run `bundle update studio-engine` here.
