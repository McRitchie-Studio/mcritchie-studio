class ApplicationMailer < ActionMailer::Base
  default from: -> { Studio.mailer_from || "McRitchie Studio <team@mcritchie.studio>" }
end
