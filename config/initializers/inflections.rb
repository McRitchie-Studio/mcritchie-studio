# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym "RESTful"
# end

ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "OAuth"
end

# studio-engine (>= 0.5.0) ships app/services/google_oauth_validator.rb defining
# `GoogleOauthValidator` (Zeitwerk's DEFAULT camelization). Our "OAuth" acronym
# above makes the autoloader instead expect `GoogleOAuthValidator`, so production
# eager-load crashes with a Zeitwerk::NameError (dev/test don't eager-load, so it
# only surfaces on a Heroku boot). Pin this one basename back to the engine's
# casing — surgical, leaves the global acronym intact for everything else.
Rails.autoloaders.main.inflector.inflect("google_oauth_validator" => "GoogleOauthValidator")
