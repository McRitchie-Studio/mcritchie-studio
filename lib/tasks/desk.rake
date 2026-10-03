namespace :desk do
  # Is mail to team@ reaching the desk? MX for in.mcritchie.studio plus a
  # Resend-vs-DeskCaptureItem ingest reconciliation (DeskCapture::Health).
  # `bin/mail doctor` runs the same check on production; DeskHealthJob runs it
  # daily and files an ErrorLog when it fails.
  desc "Check the team@ inbound path: MX record and dropped Resend ingests (exit 1 on failure)"
  task health: :environment do
    result = DeskCapture::Health.new.check
    puts result.message
    if result.ok?
      puts "desk:health OK"
    else
      warn "desk:health FAILED — #{result.failures.size} problem(s) above"
      exit 1
    end
  end
end
