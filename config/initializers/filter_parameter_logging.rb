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
  # A feedback survey's answers (task first-game-feedback-survey) are what a
  # reader told Alex, never the log's: the whole `answers` hash is masked.
  /\Aanswers\z/
]
