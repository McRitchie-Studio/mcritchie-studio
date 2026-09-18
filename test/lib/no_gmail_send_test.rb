require "test_helper"

# [unit] THE SEND BAN. Nothing in this codebase may put mail in flight.
#
# The `gmail.compose` scope this credential holds DOES permit sending — there is
# no draft-only Gmail scope — so "never sends" is a property of the source, not
# of the grant. This file is what makes that property checkable.
#
# WHY IT SCANS FOR WHAT IT SCANS FOR. The obvious test greps for the REST path
# "users.messages.send". That string appears nowhere in a Ruby codebase using
# google-apis-gmail_v1, so the obvious test passes forever while
# `send_user_message` sits in a service — a guard that cannot fail. The scan
# therefore targets the gem's real method names, and the last test in this file
# proves the detector fires on a sample that contains one.
class NoGmailSendTest < ActiveSupport::TestCase
  ROOT = Rails.root

  # Directories that SHIP or RUN. test/ is included because a test that sends
  # mail sends mail; this file is excluded by name since it must say the words.
  SCANNED_DIRS = %w[app lib bin config db].freeze
  SCANNED_TEST_DIRS = %w[test].freeze
  SELF = "test/lib/no_gmail_send_test.rb".freeze

  # Each pattern with what it catches, so a future reader can tell whether a new
  # API surface is covered.
  #
  # THESE BAN AN INVOCATION, NOT A WORD, and that distinction is load-bearing.
  # A bare /\bsend_user_message\b/ flags the very files that exist to forbid it —
  # GmailClient::FORBIDDEN_GEM_CALLS and its test — and the only way to quiet
  # that is to exclude the Gmail client from the scan, which is exactly the file
  # where a send would most plausibly be added. So the patterns match a call on a
  # receiver, a bare call with parens, or a symbol or QUOTED name handed to
  # dispatch; a %w[] declaration or a bare quoted name matches none of them.
  SEND_CALLS = "send_user_(?:message|draft)".freeze

  FORBIDDEN = {
    # google-apis-gmail_v1's two send calls. The draft one is the sneaky half:
    # it sends a draft, so code that never "sends a message" can still post mail.
    /\.#{SEND_CALLS}\b/o => "a GmailService send call on a receiver",
    /(?<![\w:."'])#{SEND_CALLS}\s*\(/o => "a bare GmailService send call",
    /:#{SEND_CALLS}\b/o => "a GmailService send call via symbol dispatch",
    /(?::|\b(?:send|__send__|public_send|method|try)\s*\(?\s*:?)["']#{SEND_CALLS}["']/o =>
      "a GmailService send call via string or quoted-symbol dispatch",
    # The REST paths, in case anything ever hand-rolls the HTTP call — for ANY
    # user segment: `me`, the gem's own `{userId}` template, or an interpolation.
    %r{users/[^/\s"']+/messages/send} => "the messages.send REST path",
    %r{users/[^/\s"']+/drafts/send} => "the drafts.send REST path",
    # The scope that would make sending possible even without the calls above.
    %r{auth/gmail\.send} => "the gmail.send scope"
  }.freeze

  # Binary assets carry no Ruby and their bytes are not valid UTF-8, so they are
  # skipped by extension rather than scanned and scrubbed.
  BINARY_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .ico .pdf .woff .woff2 .ttf .eot
                         .zip .gz .mp4 .mov .xlsx .docx .sqlite3].freeze

  def scanned_files
    files = (SCANNED_DIRS + SCANNED_TEST_DIRS).flat_map { |dir| Dir.glob(ROOT.join(dir, "**/*")) }
    files.select { |path| File.file?(path) }
         .reject { |path| path.end_with?(SELF) }
         .reject { |path| path.include?("/node_modules/") || path.include?("/tmp/") }
         .reject { |path| BINARY_EXTENSIONS.include?(File.extname(path).downcase) }
  end

  # Read the bytes and SCRUB. `File.read(encoding: "UTF-8", invalid: :replace)`
  # looks like it handles this and does not — those options apply only when a
  # transcode actually happens, so one stray byte in one fixture raised
  # ArgumentError and took the whole scan down with it.
  def read_text(path)
    File.binread(path).force_encoding(Encoding::UTF_8).scrub
  end

  def offenders_in(text)
    FORBIDDEN.filter_map { |pattern, description| description if text.match?(pattern) }
  end

  test "no source file can put mail in flight" do
    offences = scanned_files.filter_map do |path|
      text = read_text(path)
      found = offenders_in(text)
      "#{Pathname.new(path).relative_path_from(ROOT)}: #{found.join(', ')}" if found.any?
    end

    assert_empty offences,
                 "Mail must never be SENT from this codebase — every pipeline ends at a draft " \
                 "plus a URL that a human opens.\n#{offences.join("\n")}\n" \
                 "If a send is ever genuinely wanted it is a deliberate decision by the " \
                 "operator, with its own task and its own credential — not a line added here."
  end

  test "the scan actually reaches the source it claims to" do
    # A scan over an empty file list passes trivially. Pin that it sees the real
    # tree, and specifically the client that would be the place to add a send.
    files = scanned_files

    assert_operator files.size, :>, 50, "the glob collapsed — this scan would pass over nothing"
    assert_includes files.map { |p| Pathname.new(p).relative_path_from(ROOT).to_s },
                    "app/services/workspace/gmail_client.rb"
  end

  test "the detector FIRES on each forbidden shape" do
    # Proves the guard bites. Without this, a typo in a pattern would leave the
    # suite green and the ban unenforced.
    samples = {
      'service.send_user_message("me", message)' => "send_user_message on a receiver",
      'service.send_user_draft("me", draft)' => "send_user_draft on a receiver",
      'send_user_message("me", message)' => "a bare send call",
      'service.public_send(:send_user_message, "me", message)' => "symbol dispatch",
      'post("users/me/messages/send")' => "messages.send REST",
      'post("users/me/drafts/send")' => "drafts.send REST",
      'service.public_send("send_user_draft", "me", id)' => "string dispatch",
      'service.__send__(:"send_user_message", "me", m)' => "quoted-symbol dispatch",
      'post("gmail/v1/users/#{uid}/messages/send")' => "messages.send REST, interpolated user",
      "command(:post, 'gmail/v1/users/{userId}/drafts/send')" => "drafts.send REST, gem template",
      '"https://www.googleapis.com/auth/gmail.send"' => "gmail.send scope"
    }

    samples.each do |sample, label|
      refute_empty offenders_in(sample), "the scan missed #{label}"
    end
  end

  test "it does not false-positive on the legitimate surface" do
    # send-as SETTINGS, public_send, and our own draft calls must all pass, or
    # the guard gets disabled by the first person it annoys.
    [
      'service.create_user_draft("me", draft)',
      'service.update_user_draft("me", id, draft)',
      'service.list_user_setting_send_as("me")',
      'service.get_user_setting_send_as("me", email)',
      "object.public_send(:name)",
      "record.send(:private_thing)",
      '"https://www.googleapis.com/auth/gmail.compose"',
      # The ban list DECLARING the names it bans, and a test asserting on them.
      # If these ever match, the guard eats its own enforcement.
      "FORBIDDEN_GEM_CALLS = %w[send_user_message send_user_draft].freeze",
      'assert_includes surface, "send_user_message"'
    ].each do |sample|
      assert_empty offenders_in(sample), "false positive on: #{sample}"
    end
  end
end
