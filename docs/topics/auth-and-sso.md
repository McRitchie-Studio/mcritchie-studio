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
  config.registration_params = [:name, :email, :password, :password_confirmation]
  config.configure_sso_user = ->(user) { user.role = "viewer" }
  config.theme_logos = %w[logo-icon.svg icon.svg icon.png studio-logo.svg favicon.png]
end
```

**From the engine:** `Studio::ErrorHandling` concern (in ApplicationController), `ErrorLog` model, `Sluggable` concern, auth controllers (sessions, registrations, omniauth_callbacks, error_logs), error log views, generic login/signup views (overridden by app-branded versions).

**Overridden locally:** `sessions/new.html.erb` and `registrations/new.html.erb` (branded with logo, uses `btn btn-primary`).

**Routes:** `Studio.routes(self)` in `config/routes.rb` draws `/login`, `/signup`, `/logout`, `/sso_continue`, `/sso_login`, `/auth/:provider/callback`, `/auth/failure`, `/error_logs`, `/admin/theme` (GET + PATCH), `/admin/theme/regenerate`.

## SSO Hub Role

This app is the central auth hub for apps that opt into Studio SSO. On login,
`set_app_session` stores `sso_*` fields (including `sso_logo`) in the shared
session. The generic satellite pattern points authenticated navbar links at
`/sso_login` on each satellite app; SSO-created users on satellite apps get
`role = "viewer"` via `configure_sso_user`. Requires compatible session secrets.

Current caveat: Turf Monster intentionally disables cross-app SSO and 404s
`/sso_login` / `/sso_continue` while the money-app cookie stays isolated on
`app.turfmonster.media`. Use direct magic-link login for Turf Monster smoke
tests until SSO is redesigned and re-enabled.

The McRitchie Studio login page does NOT show "Continue as" because the hub is a
sender, not a receiver.

**Updating:** After changes to the studio repo, run `bundle update studio-engine` here.
