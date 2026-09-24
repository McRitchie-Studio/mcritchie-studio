namespace :workspace do
  # Drafting as named mailboxes inside registered workspaces. The workspace
  # tasks in workspace.rake prove the DOMAIN's delegation; these add the
  # addresses we may draft as, prove each one, write drafts, and end a
  # relationship for good. Nothing here can send — see Workspace::Drafter.

  desc "Allow-list a mailbox to draft as: workspace:add_mailbox[address] (SIGNATURE='markdown' optional)"
  task :add_mailbox, [ :address ] => :environment do |_t, args|
    address = WorkspaceMailbox.normalize_address(args[:address])
    abort "usage: bin/rails 'workspace:add_mailbox[<address>]'" if address.empty?

    domain = address.split("@", 2).last
    account = WorkspaceAccount.find_by(domain: domain)
    abort "No workspace registered for #{domain}. Run bin/rails 'workspace:register[#{domain}]' first." if account.nil?
    abort "#{domain} is #{account.status} — no new mailboxes." if account.shut?

    mailbox = account.workspace_mailboxes.find_or_initialize_by(address: address)
    mailbox.signature = ENV["SIGNATURE"] if ENV.key?("SIGNATURE")
    mailbox.save!
    puts "#{mailbox.address}: allow-listed in #{domain} (#{mailbox.status})"
    puts "  Prove it: bin/rails 'workspace:check_mailbox[#{mailbox.address}]'"
  end

  desc "List allow-listed mailboxes and their drafts"
  task mailboxes: :environment do
    WorkspaceMailbox.includes(:workspace_account).order(:address).each do |m|
      verified = m.verified_at ? m.verified_at.utc.iso8601 : "never"
      puts "#{m.address.ljust(36)} #{m.status.ljust(8)} workspace #{m.workspace_account.status.ljust(8)} " \
           "verified #{verified} · #{m.mailbox_drafts.count} draft(s)" \
           "#{" — last refusal: #{m.last_check_error}" if m.last_check_error}"
    end
    puts "(no mailboxes — bin/rails 'workspace:add_mailbox[<address>]')" if WorkspaceMailbox.none?
  end

  desc "Prove one mailbox can be drafted as, and flip it active: workspace:check_mailbox[address]"
  task :check_mailbox, [ :address ] => :environment do |_t, args|
    unless Workspace::Credentials.configured?
      warn "No Google credential. Set GOOGLE_SERVICE_ACCOUNT_JSON, or file it at #{Workspace::Credentials::ITEM}."
      exit 1
    end

    mailbox = WorkspaceMailbox.find_by(address: WorkspaceMailbox.normalize_address(args[:address]))
    abort "No mailbox #{args[:address].inspect}. Add it: bin/rails 'workspace:add_mailbox[<address>]'" if mailbox.nil?

    account = mailbox.workspace_account
    # Shut rows are never probed — the same rule workspace:check keeps.
    abort "#{mailbox.address}: SKIPPED — workspace #{account.domain} is #{account.status}." if account.shut?
    abort "#{mailbox.address}: SKIPPED — mailbox is revoked." if mailbox.status == "revoked"

    ok, error = Workspace::Credentials.probe(mailbox.address)
    unless ok
      mailbox.mark_unverified!(error)
      warn "#{mailbox.address}: NOT AUTHORIZED (#{error})"
      warn "  → #{account.domain}'s super-admin grants delegation to client id " \
           "#{Workspace::Credentials.credential['client_id']} with scopes #{Workspace::Credentials::SCOPES.join(',')}"
      exit 1
    end

    # Delegation is domain-wide, so a token for this address proves the
    # WORKSPACE's grant too. Flip a pending workspace with it — both flips come
    # before the smoke read, because the read goes through authorizer_for.
    account.mark_verified! unless account.active?
    mailbox.mark_verified!
    profile = Workspace::GmailClient.new(subject: mailbox.address).service.get_user_profile("me")
    puts "#{mailbox.address}: ACTIVE — Gmail answered as #{profile.email_address}"
  rescue WorkspaceAccount::Revoked => e
    abort e.message
  end

  desc "Stop drafting as one mailbox: workspace:revoke_mailbox[address,reason]"
  task :revoke_mailbox, [ :address, :reason ] => :environment do |_t, args|
    mailbox = WorkspaceMailbox.find_by(address: WorkspaceMailbox.normalize_address(args[:address]))
    abort "No mailbox #{args[:address].inspect}." if mailbox.nil?

    mailbox.revoke!(args[:reason])
    puts "#{mailbox.address}: REVOKED — drafting as it is refused from the next call."
  end

  desc "Print the ONE thread a query names, for drafting a reply: MAILBOX=… QUERY='…' bin/rails workspace:thread"
  task thread: :environment do
    mailbox = ENV["MAILBOX"].to_s
    query = ENV["QUERY"].to_s
    abort "usage: MAILBOX=<address> QUERY='<gmail query naming one thread>' bin/rails workspace:thread" if
      mailbox.empty? || query.strip.empty?
    abort "#{mailbox} is not an active mailbox." unless WorkspaceMailbox.impersonatable?(mailbox)

    puts Workspace::ThreadFinder.new(Workspace::GmailClient.new(subject: mailbox)).transcript(query)
  rescue Workspace::ThreadFinder::Error => e
    abort e.message
  end

  desc "Write a draft (never sends): MAILBOX= BY= BODY=<file.md> [TO= SUBJECT= CC= REPLY_QUERY=] bin/rails workspace:draft"
  task draft: :environment do
    body_path = ENV["BODY"].to_s
    abort "usage: MAILBOX=<address> BY=<who> BODY=<markdown file> TO=<a,b> SUBJECT='…' " \
          "[CC=…] [REPLY_QUERY='<gmail query naming one thread>'] bin/rails workspace:draft" if
      ENV["MAILBOX"].to_s.empty? || body_path.empty?

    markdown = body_path == "-" ? $stdin.read : File.read(body_path)
    result = Workspace::Drafter.new(mailbox: ENV["MAILBOX"], drafted_by: ENV["BY"]).call(
      to: ENV["TO"], cc: ENV["CC"], subject: ENV["SUBJECT"], markdown: markdown, reply_query: ENV["REPLY_QUERY"]
    )

    puts "Draft saved in #{result.log.mailbox_address} (NOT sent)"
    puts "  To:      #{result.log.recipients}"
    puts "  Subject: #{result.log.subject}"
    puts "  Thread:  #{result.thread_id || '(new conversation)'}"
    puts "  Open:    #{result.url}"
  rescue Workspace::Drafter::Error, Workspace::ThreadFinder::Error, ArgumentError, Errno::ENOENT => e
    abort "workspace:draft refused: #{e.message}"
  end

  desc "Prove the Google side is cut (our client id removed): workspace:check_severed[domain]"
  task :check_severed, [ :domain ] => :environment do |_t, args|
    account = WorkspaceAccount.find_by(domain: args[:domain].to_s.strip.downcase)
    abort "No workspace registered for #{args[:domain]}." if account.nil?

    ok, error = Workspace::Credentials.probe(account.subject)
    if ok
      warn "#{account.domain}: STILL AUTHORIZED — Google issued a token as #{account.subject}."
      warn "  → the client's super-admin must remove client id #{Workspace::Credentials.credential['client_id']} " \
           "from their domain-wide delegation page."
      exit 1
    end

    # ONLY unauthorized_client proves the grant is gone. Any other failure — no
    # credential, a network error — says nothing about the client's console,
    # and reading it as "cut" would record a severance Google never agreed to.
    unless error == "unauthorized_client"
      warn "#{account.domain}: INCONCLUSIVE (#{error}) — this failure does not prove the grant was removed."
      exit 1
    end

    puts "#{account.domain}: CUT — Google refuses our client id (unauthorized_client)."
  end

  desc "End a workspace for good (after check_severed passes): workspace:sever[domain,reason]"
  task :sever, [ :domain, :reason ] => :environment do |_t, args|
    account = WorkspaceAccount.find_by(domain: args[:domain].to_s.strip.downcase)
    abort "No workspace registered for #{args[:domain]}." if account.nil?
    abort "usage: bin/rails 'workspace:sever[<domain>,<why>]' — a reason is required" if args[:reason].blank?

    # The order is the point: the record says "severed" only once Google agrees.
    # To stop drafting BEFORE the client acts, revoke — that is reversible.
    ok, error = Workspace::Credentials.probe(account.subject)
    if ok || error != "unauthorized_client"
      abort "#{account.domain}: NOT severed — Google #{ok ? 'still issues a token' : "answered #{error}"}. " \
            "Revoke now (bin/rails 'workspace:revoke[#{account.domain},<why>]'), and sever once " \
            "bin/rails 'workspace:check_severed[#{account.domain}]' reports CUT."
    end

    account.sever!(args[:reason])
    puts "#{account.domain}: SEVERED — final. #{account.workspace_mailboxes.count} mailbox(es) shut with it."
  end
end
