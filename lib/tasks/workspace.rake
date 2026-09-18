namespace :workspace do
  desc "Prove the Google Workspace credential and name what it can reach (reads nothing else)"
  task check: :environment do
    unless Workspace::Credentials.configured?
      warn "No Google credential. Set GOOGLE_SERVICE_ACCOUNT_JSON, or file it at " \
           "#{Workspace::Credentials::ITEM}."
      exit 1
    end

    key = Workspace::Credentials.credential
    puts "Credential source: #{Workspace::Credentials.source}"
    puts "Service account:   #{key['client_email']}"
    puts "Project:           #{key['project_id']}"
    # Read back off the built authorizer, not off the constant: the subject
    # assignment is a separate line that fails silently when missed.
    puts "Impersonating:     #{Workspace::Credentials.subject}"
    puts "Scopes:"
    Workspace::Credentials::SCOPES.each { |scope| puts "  #{scope}" }
    puts
    puts "Drive:  #{Workspace::DriveClient.new.files_list(query: 'trashed = false', limit: 1).files&.size.to_i} " \
         "file(s) reachable on the first page"
    puts "Gmail:  profile #{Workspace::GmailClient.new.service.get_user_profile('me').email_address}"
  rescue Workspace::Credentials::Malformed => e
    warn "workspace:check FAILED — the credential is filed but unusable: #{e.message}"
    exit 1
  rescue Google::Apis::AuthorizationError, Google::Apis::ClientError => e
    warn "workspace:check FAILED — Google refused: #{e.class}: #{e.message}"
    warn "If this is a 403 on Drive or Gmail, domain-wide delegation is probably not granted " \
         "for all of #{Workspace::Credentials::SCOPES.size} scopes, or the subject " \
         "#{Workspace::Credentials::SUBJECT} does not exist in the domain."
    exit 1
  end
end
