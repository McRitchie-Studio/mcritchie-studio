# The hub's Content-Security-Policy. REPORT-ONLY: browsers send it as
# Content-Security-Policy-Report-Only, block nothing, and POST each violation to
# /csp_reports (CspReportsController → CspReport, read at /admin/csp_reports or
# `bin/rails csp:reports`). Alex McRitchie decided "CSP yes" for every app on 2026-10-06;
# the flip to enforcing waits on the data: zero genuine violations across 7 days
# (studio-engine docs/FRONT_END_STANDARD.md, the CSP section, has the criterion
# and what is still in the way).
#
# The client-app preview host never reaches this policy: ClientApps::Host answers
# those requests before the CSP middleware, with its own bundle policy
# (docs/agents/system/client-app-host.md).
#
# WHAT EACH DIRECTIVE ALLOWS, measured from the pages on 2026-10-24:
#
#   script-src   'self' (importmap modules, the engine's vendored Alpine, confetti,
#                Leaflet, SortableJS), the request's nonce (every inline <script>
#                renders nonce="<%= content_security_policy_nonce %>"; importmap-rails
#                and the engine's head nonce their own tags), and ONE third-party
#                file, named by path rather than host because cdnjs mirrors every
#                npm package: cropper.js (studio/_cropper_assets, the avatar and
#                banner croppers). And Google's API loader host, apis.google.com:
#                the Drive card's Google Picker (drive_picker.js) loads
#                /js/api.js from it, and that loader fetches the Picker's own
#                scripts from the same host (/tasks/drive-files-you-pick).
#                'unsafe-eval' stays while Alpine runs: Alpine
#                evaluates every x-data, x-on and :binding with new Function, and the
#                hub's body is x-data on every page. 'report-sample' makes a report
#                quote the first 40 characters it would block.
#                PINNED_SCRIPT_HASHES: see below.
#   style-src    'unsafe-inline', IN THIS REPORT-ONLY PHASE ONLY. The hub's views
#                carry 387 inline style="" attributes and the engine renders about 35
#                <style> blocks with no nonce. A nonce here would make browsers ignore
#                'unsafe-inline' and report every one of them on every page, burying
#                the script reports this phase exists to collect. So style-src gets no
#                nonce yet (nonce_directives is script-src only).
#   img-src      'self', data:, blob: and https:. Images come from R2
#                (assets.mcritchie.studio, presigned Active Storage redirects), Google
#                avatars, OpenStreetMap tiles (the footer map) and model output URLs; an
#                image cannot run code, and a named list would only fill the table.
#   media-src    'self', blob:, R2's public host and presigned R2 URLs (the video
#                pages play R2 files).
#   connect-src  'self' and this host's websocket origin (Action Cable, Turbo
#                Streams); every fetch the front end makes is same-origin.
#   frame-src    'self' (the broadcast and email-image previews), Google
#                Calendar (the booking popup, Studio.booking_url) and
#                docs.google.com, the Google Picker's own frame.
#   frame-ancestors 'self': the same-origin preview iframes frame hub pages; nothing
#                else may (what X-Frame-Options SAMEORIGIN already says).
#   form-action  'self' and accounts.google.com: Sign in with Google posts to
#                /auth/google_oauth2, which redirects there, and form-action covers
#                the redirect.
#   report-uri   /csp_reports. NOT report-to, measured: with report-to and a
#                Reporting-Endpoints header (relative or absolute) Chromium posted
#                nothing in 80 seconds, and a browser that knows report-to ignores
#                report-uri, so Chrome's reports would be lost; with report-uri alone
#                the report arrived within two seconds (2026-10-24, Playwright
#                Chromium against the test server).
#
# NEVER READ A DIRECTIVE BY CALLING IT. policy.script_src with no arguments returns
# the list AND sets it to nil (docs/agents/modules/backend-discipline.md, Rails
# Traps). Read policy.directives["script-src"].
module HubCsp
  REPORT_PATH = "/csp_reports".freeze

  CROPPER_JS = "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js".freeze
  CROPPER_CSS = "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.css".freeze
  R2_PUBLIC = "https://assets.mcritchie.studio".freeze
  R2_PRESIGNED = "https://*.r2.cloudflarestorage.com".freeze
  GOOGLE_CALENDAR = "https://calendar.google.com".freeze
  GOOGLE_ACCOUNTS = "https://accounts.google.com".freeze
  # The Google Picker (/tasks/drive-files-you-pick): its loader's host, and the frame it opens.
  GOOGLE_APIS = "https://apis.google.com".freeze
  GOOGLE_PICKER_FRAME = "https://docs.google.com".freeze
  # The voice row on /profile (studio-engine docs/VOICE_PROFILE.md): the
  # speaker model's runtime (transformers.js) and its onnxruntime WebAssembly,
  # both from this one jsDelivr package path (a path, not the whole CDN; keep
  # the version equal to Studio::VoiceMatch::TRANSFORMERS_VERSION), and the
  # model itself from Hugging Face, which redirects the file to *.hf.co.
  TRANSFORMERS_JS = "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.7.6/".freeze
  HUGGING_FACE = "https://huggingface.co".freeze
  HUGGING_FACE_FILES = "https://*.hf.co".freeze

  # Inline scripts that run on EVERY page from the layout body, allowed by their
  # SHA-256 as well as (where we control the tag) the nonce. Why a hash too: a Turbo
  # visit re-runs every <script> in the new body and Turbo stamps it with the NEW
  # page's nonce, which the document's policy (fixed at the full load) does not
  # accept. These scripts guard themselves to once per document, so blocking a
  # re-run would break nothing, but each would be reported on every visit. The hash
  # is the same on every request, so it keeps them quiet without carrying a nonce
  # across documents, which would trust whatever Turbo brings in.
  #
  #   studio/_at_time_script   the engine renders it with NO nonce (studio-engine
  #                            app/views/studio/_at_time_script.html.erb). Until the
  #                            engine nonces it, the hash is the only thing that
  #                            allows it; afterwards it stays for the Turbo reason.
  #   layouts/application      the hub layout's three body scripts (modal widths,
  #                            the first-name ask, postMagicLink).
  #
  # test/integration/content_security_policy_test.rb renders the layout and fails
  # when a script's text changes without its hash, printing the new value.
  PINNED_SCRIPT_HASHES = {
    "studio/_at_time_script" => "sha256-kIOuRYmYbGVrhT216UVVU2pt1rRgLf4S5n9hII0ZEHo=",
    "layouts/application modal widths" => "sha256-aZcDxynz/nxhgNobHNVgLXf13ltywKQzafn8neCF3xk=",
    "layouts/application first-name ask" => "sha256-PRFP/EDlSi+SUsL7i6U6qlsmZcknKOhZjvLW7EsH9jU=",
    "layouts/application postMagicLink" => "sha256-WO33zDNlb0N5B0PL471ZBnOPKagrrd+xHHcKKVWRWiY="
  }.freeze

  # The websocket origin of the request (Action Cable is mounted on this host).
  # Evaluated in the controller, or in the bare request when no controller ran.
  CABLE_ORIGIN = lambda do
    req = is_a?(ActionDispatch::Request) ? self : request
    "#{req.ssl? ? 'wss' : 'ws'}://#{req.host_with_port}"
  end

  # The public R2 origin this deploy serves files from, when it is not the
  # production one (QA's dev bucket). Production and QA only, so the test
  # environment's policy string is fixed.
  def self.deploy_r2_origin(env = ENV)
    return nil unless Rails.env.production?

    uri = URI.parse(env["R2_PUBLIC_URL"].to_s.strip)
    origin = "https://#{uri.host}" if uri.is_a?(URI::HTTPS) && uri.host.present?
    origin unless origin == R2_PUBLIC
  rescue URI::InvalidURIError
    nil
  end

  def self.media_sources
    [ :self, :blob, R2_PUBLIC, deploy_r2_origin, R2_PRESIGNED ].compact
  end
end

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.script_src      :self, :unsafe_eval, :report_sample, HubCsp::CROPPER_JS, HubCsp::GOOGLE_APIS, HubCsp::TRANSFORMERS_JS, *HubCsp::PINNED_SCRIPT_HASHES.values
    policy.style_src       :self, :unsafe_inline, HubCsp::CROPPER_CSS
    policy.img_src         :self, :data, :blob, :https
    policy.media_src(*HubCsp.media_sources)
    policy.font_src        :self, :data
    policy.connect_src     :self, HubCsp::CABLE_ORIGIN, HubCsp::TRANSFORMERS_JS, HubCsp::HUGGING_FACE, HubCsp::HUGGING_FACE_FILES
    policy.frame_src       :self, HubCsp::GOOGLE_CALENDAR, HubCsp::GOOGLE_PICKER_FRAME
    policy.worker_src      :self, :blob
    policy.object_src      :none
    policy.frame_ancestors :self
    policy.base_uri        :self
    policy.form_action     :self, HubCsp::GOOGLE_ACCOUNTS
    policy.report_uri      HubCsp::REPORT_PATH
  end

  # THE ENFORCE SWITCH. true: report only. The flip criterion is in the header.
  config.content_security_policy_report_only = true

  # A fresh nonce per request, never per session: a nonce means "the server wrote
  # this tag into this document", and a session nonce would also bless a script
  # that a Turbo visit brings into a later document.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
