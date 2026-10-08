# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # /contacts searches by part of an email in `q`. Anchored: a bare :q would
  # partial-match every key containing a "q" (request, query, sequence).
  /\Aq\z/,
  # The public /contact form: a visitor's mobile number and message stay out of
  # the request log. Matched on the nested key (a regexp containing "\." is
  # tested against the full dotted path), because a bare :message would also
  # mask every other `message` param and, through filter_attributes, every
  # model's `message` column in an inspect. ContactSubmission filters its own.
  /\Acontact_submission\.(phone|message)\z/,
  # A fact's value, nested (`fact.value`) and at the top level of a facts API
  # request. Scoped to that controller: a bare :value would mask every `value`
  # param. Fact filters its own column. The lambda below can only rewrite a
  # String, so Api::V1::FactsController#mask_logged_parameters masks a number or
  # a boolean, and every other parameter that is not a name.
  /\Afact\.value\z/,
  # An admin login's one-time code, nested and at the top level of its own API.
  /\Aagent_login_request\.code\z/,
  lambda do |key, value, params = nil|
    next unless key.to_s == "code" && value.is_a?(String)

    value.replace("[FILTERED]") if params.is_a?(Hash) && params["controller"].to_s == "api/v1/agent_login_requests"
  end,
  # The TikTok sign-in's single-use auth code, on its callback only.
  lambda do |key, value, params = nil|
    next unless key.to_s == "code" && value.is_a?(String)

    value.replace("[FILTERED]") if params.is_a?(Hash) && params["controller"].to_s == "admin/tiktok"
  end,
  lambda do |key, value, params = nil|
    next unless key.to_s == "value" && value.is_a?(String)

    value.replace("[FILTERED]") if params.is_a?(Hash) && params["controller"].to_s == "api/v1/facts"
  end
]
