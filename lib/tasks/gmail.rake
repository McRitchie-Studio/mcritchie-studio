namespace :gmail do
  desc "Pull matching mail from the Gmail mailbox into the desk capture queue"
  task pull: :environment do
    result = Gmail::MailboxIngest.new.call

    if result.error
      # LOUD. A revoked credential or a misfiled item must never read as a quiet
      # mailbox — that is exactly how a capture lane goes unnoticed for weeks
      # (the slack:pull "No Slack token, exit 0" scar, deliberately not repeated).
      warn "gmail:pull FAILED for #{result.mailbox}: #{result.error}"
      ErrorLog.capture!(StandardError.new("gmail:pull: #{result.error}")) if defined?(ErrorLog)
      exit 1
    end

    if result.mode.start_with?("skipped")
      # Nothing to pull and nothing broken: a desk without `op`, or a query not
      # yet configured. Exit 0 so the suite and a fresh checkout stay green —
      # unless the caller is a scheduler, which wants this to be a failure.
      warn "gmail:pull #{result.mode}"
      exit 1 if ENV["GMAIL_PULL_STRICT"].present?
      next
    end

    puts "Credential source: #{Gmail::Credentials.source || 'injected'}"
    puts "#{result.mailbox} [#{result.mode}]: #{result.matched} matched, " \
         "#{result.ingested} new, #{result.skipped} already held" \
         "#{", #{result.quarantined} QUARANTINED" if result.quarantined.positive?}"
    puts "Queue: /admin/desk — run the knowledge-capture intake protocol over the new items."
  end

  desc "Prove the Gmail credential and name the mailbox it opens (reads nothing else)"
  task check: :environment do
    unless Gmail::Credentials.configured?
      warn "No Gmail credential. Set GMAIL_OAUTH_CREDENTIAL, or file it at #{Gmail::Credentials::ITEM}."
      exit 1
    end

    profile = Gmail::Client.new.profile
    puts "Credential source: #{Gmail::Credentials.source}"
    puts "Scopes:            #{Gmail::Client::SCOPES.join(', ')}"
    puts "Mailbox:           #{profile['emailAddress']}"
    puts "Messages total:    #{profile['messagesTotal']}"
    puts "History id:        #{profile['historyId']}"
    puts "Recorded cursor:   #{DeskCaptureItem.gmail_cursor || '(none yet)'}"
    puts "Query:             #{Gmail::MailboxIngest.query.presence || '(UNSET — gmail:pull will refuse)'}"
  rescue Gmail::Client::CredentialRevoked, Gmail::Credentials::Malformed => e
    warn "gmail:check FAILED: #{e.message}"
    exit 1
  end
end
