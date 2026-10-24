require "test_helper"
require_relative "../../support/agent_email_fixtures"

# [unit] Who sent an email (AgentMessages::EmailTrust): only the TOPMOST
# Authentication-Results, only from amazonses.com, only inside SES's own trace
# block, with DKIM aligned to the From domain AND DMARC passing. Every other
# Authentication-Results line, forged or real, is ignored.
class EmailTrustTest < ActiveSupport::TestCase
  include AgentEmailFixtures

  def verdict(raw) = AgentMessages::EmailTrust.verdict(raw)

  test "the fixture really carries the SES verdict this suite swaps" do
    assert_includes agent_email_base, SES_RESULT, "the fixture must hold SES_RESULT verbatim, or every swap is a no-op"
  end

  test "an owner email shaped like a real team@ arrival is verified" do
    v = verdict(agent_email)
    assert v.verified?, v.reason
    assert_equal "alex@mcritchie.studio", v.from_addr
    assert_equal "mcritchie.studio", v.dkim_domain
  end

  test "a forged lower amazonses.com pass is NOT trusted when the real top verdict fails" do
    raw = agent_email(top_result: ses_result(dkim: "dkim=fail header.i=@mcritchie.studio",
                                             dmarc: "dmarc=fail header.from=mcritchie.studio"),
                      sender_headers: [ FORGED_FOLDED ])
    v = verdict(raw)
    refute v.verified?
    assert_match(/no dkim=pass aligned/, v.reason)
  end

  test "with SES's verdict missing, a forged amazonses.com pass in the sender's block is NOT trusted" do
    raw = agent_email(top_result: nil, sender_headers: [ FORGED_FOLDED ])
    v = verdict(raw)
    refute v.verified?
    assert_match(/sits below SES's X-SES-RECEIPT/, v.reason)

    # Even when the forged line is the ONLY Authentication-Results left (the
    # relay's mx.google.com one removed too), it is the topmost and still refused.
    alone = raw.sub(/^Authentication-Results: mx\.google\.com;.*\r\n(?:[ \t].*\r\n)*/, "")
    assert_equal 1, alone.scan(/^Authentication-Results:/).size
    refute verdict(alone).verified?
  end

  # Steffon's case: a sender mails SES directly (no Google hop) and writes a whole
  # fake trace block of its own. SES's receipt sits above it.
  test "a forged trace block below SES's receipt is refused when there is no relay" do
    ses_top = "Return-Path: <x@evil.example>\r\nReceived: from mx.evil.example by inbound-smtp.us-east-1.amazonaws.com\r\n" \
              "X-SES-Spam-Verdict: PASS\r\nReceived-SPF: fail\r\n"
    forged = "X-SES-RECEIPT: x\r\nReceived: by mail.evil.example\r\n#{FORGED_FOLDED}\r\n" \
             "#{dkim_signature(d: 'mcritchie.studio', s: 'google')}\r\nFrom: Alex <alex@mcritchie.studio>\r\n" \
             "To: avi@mcritchie.studio\r\nMessage-ID: <a@b>\r\nSubject: hi\r\n\r\nbody\r\n"
    v = verdict(ses_top + forged)
    refute v.verified?
    assert_match(/below SES's X-SES-RECEIPT/, v.reason)
  end

  test "with no X-SES-RECEIPT at all the sender is the public" do
    v = verdict(agent_email.sub(/^X-SES-RECEIPT: .*\r\n/, ""))
    refute v.verified?
    assert_match(/no X-SES-RECEIPT/, v.reason)
  end

  # Carl's case: SES copies the SMTP envelope-from into its verdict.
  test "a quoted envelope-from local part carrying fake results is not read" do
    spf = "spf=none (spfCheck: 203.0.113.5 is neither permitted nor denied) client-ip=203.0.113.5; " \
          'envelope-from="x;dkim=pass header.d=mcritchie.studio;dmarc=pass header.from=mcritchie.studio;"@evil.example; ' \
          "helo=evil.example;"
    v = verdict(agent_email(top_result: ses_result_with_spf(spf)))
    refute v.verified?
    assert_match(/no dkim=pass aligned/, v.reason, "the quoted text vanished; the real dkim=none decides")
  end

  test "a HELO carrying fake results (tab-separated) refuses the whole header" do
    spf = "spf=none client-ip=203.0.113.5; envelope-from=a@evil.example; " \
          "helo=x;dkim=pass\theader.d=mcritchie.studio;dmarc=pass\theader.from=mcritchie.studio;"
    v = verdict(agent_email(top_result: ses_result_with_spf(spf)))
    refute v.verified?
    assert_match(/inside another result's properties/, v.reason)

    # Only fake dkim in the HELO, the real dmarc passing: still refused.
    spf2 = "spf=pass client-ip=1.2.3.4; envelope-from=a@mcritchie.studio; helo=x;dkim=pass\theader.d=mcritchie.studio;"
    raw = agent_email(top_result: "Authentication-Results: amazonses.com;\r\n #{spf2}\r\n dkim=none;\r\n " \
                                  "dmarc=pass header.from=mcritchie.studio;\r\n")
    refute verdict(raw).verified?
  end

  test "exactly one dmarc result, and it must be the last" do
    two = "Authentication-Results: amazonses.com;\r\n spf=pass client-ip=1.2.3.4;\r\n " \
          "dmarc=fail header.from=mcritchie.studio;\r\n dkim=pass header.i=@mcritchie.studio;\r\n " \
          "dmarc=pass header.from=mcritchie.studio;\r\n"
    v = verdict(agent_email(top_result: two))
    refute v.verified?
    assert_match(/2 dmarc results/, v.reason)

    not_last = "Authentication-Results: amazonses.com;\r\n spf=pass client-ip=1.2.3.4;\r\n " \
               "dkim=pass header.i=@mcritchie.studio;\r\n dmarc=pass header.from=mcritchie.studio;\r\n " \
               "dkim=pass header.i=@mcritchie.studio;\r\n"
    v = verdict(agent_email(top_result: not_last))
    refute v.verified?
    assert_match(/not the last result/, v.reason)
  end

  test "dkim is read only from the run just before dmarc" do
    split = "Authentication-Results: amazonses.com;\r\n dkim=pass header.i=@mcritchie.studio;\r\n " \
            "spf=pass client-ip=1.2.3.4;\r\n dkim=none;\r\n dmarc=pass header.from=mcritchie.studio;\r\n"
    refute verdict(agent_email(top_result: split)).verified?
  end

  test "results written inline on the authserv-id line are refused" do
    refute verdict(agent_email(top_result: "#{FORGED_PASS}\r\n")).verified?
  end

  test "a second From written with a space before its colon is still a second From" do
    raw = agent_email.sub(/^From: /, "From : Bob <bob@evil.example>\r\nFrom: ")
    v = verdict(raw)
    refute v.verified?
    assert_match(/exactly one address/, v.reason)
  end

  # Owner trust is pinned to Alex's Google selector (config/agent_routes.yml pinned_dkim).
  test "a DKIM pass under the resend selector is not the owner" do
    raw = agent_email.sub(/^DKIM-Signature: .*\r\n/, "#{dkim_signature(d: 'mcritchie.studio', s: 'resend')}\r\n")
    v = verdict(raw)
    refute v.verified?
    assert_match(/as d=mcritchie\.studio s=resend, not the pinned d=mcritchie\.studio s=google/, v.reason)

    both = agent_email.sub(/^DKIM-Signature: /, "#{dkim_signature(d: 'mcritchie.studio', s: 'resend')}\r\nDKIM-Signature: ")
    refute verdict(both).verified?, "a real s=google signature beside a resend one does not rescue it"

    none = agent_email.sub(/^DKIM-Signature: .*\r\n/, "")
    refute verdict(none).verified?, "no aligned signature to read the selector from"
  end

  # Carl's review of ctos-answer-team-email, hardening note 1: the pin is the exact
  # (d, s) pair, so a google selector on a subdomain key does not prove the domain.
  test "a pinned selector under a subdomain signing domain is not the pinned key" do
    sub = agent_email.sub(/^DKIM-Signature: .*\r\n/, "#{dkim_signature(d: 'mail.mcritchie.studio', s: 'google')}\r\n")
    v = verdict(sub)
    refute v.verified?, "d=mail.mcritchie.studio s=google aligns relaxed, but is not d=mcritchie.studio"
    assert_match(/as d=mail\.mcritchie\.studio s=google, not the pinned d=mcritchie\.studio s=google/, v.reason)

    beside = agent_email.sub(/^DKIM-Signature: /, "#{dkim_signature(d: 'mail.mcritchie.studio', s: 'google')}\r\nDKIM-Signature: ")
    refute verdict(beside).verified?, "a subdomain google signature beside the real one still refuses"

    assert verdict(agent_email).verified?, "the exact pinned pair still verifies"
  end

  test "the pin is read from config: an unpinned domain needs no selector, the pinned list can widen" do
    raw = agent_email.sub(/^DKIM-Signature: .*\r\n/, "#{dkim_signature(d: 'mcritchie.studio', s: 'resend')}\r\n")
    assert AgentMessages::EmailTrust.verdict(raw, pinned: { "mcritchie.studio" => %w[google resend] }).verified?
    assert AgentMessages::EmailTrust.verdict(raw, pinned: { "other.example" => %w[google] }).verified?
  end

  test "a forged verdict above a non-trace header is refused even at the top of the raw" do
    raw = agent_email(top_result: nil, extra_top: [ "X-Forged: 1", FORGED_FOLDED ])
    refute verdict(raw).verified?
  end

  test "no Authentication-Results at all is untrusted" do
    raw = agent_email(top_result: nil).gsub(/^(ARC-)?Authentication-Results:.*\r\n(?:[ \t].*\r\n)*/i, "")
    v = verdict(raw)
    refute v.verified?
    assert_equal "no Authentication-Results header", v.reason
  end

  test "a topmost verdict from another authserv-id is untrusted, whatever it says" do
    refute verdict(agent_email(top_result: ses_result(authserv: "mx.google.com"))).verified?
    refute verdict(agent_email(top_result: ses_result(authserv: "amazonses.com.evil.example"))).verified?
  end

  test "DKIM must align with the From domain: Google's default gappssmtp key does not" do
    raw = agent_email(top_result: ses_result(dkim: "dkim=pass header.i=@mcritchie-studio.20251104.gappssmtp.com"))
    v = verdict(raw)
    refute v.verified?
    assert_match(/gappssmtp/, v.reason)
  end

  test "a spoofed From with the spoofer's own aligned DKIM is someone else, not alex@" do
    raw = agent_email(from: "Alex <alex@mcritchie.studio>",
                      top_result: ses_result(dkim: "dkim=pass header.d=evil.example", dmarc: "dmarc=fail header.from=mcritchie.studio"))
    refute verdict(raw).verified?
  end

  test "DMARC must pass for the From domain" do
    refute verdict(agent_email(top_result: ses_result(dmarc: "dmarc=fail header.from=mcritchie.studio"))).verified?
    refute verdict(agent_email(top_result: ses_result(dmarc: "dmarc=none header.from=mcritchie.studio"))).verified?
    refute verdict(agent_email(top_result: ses_result(dmarc: "dmarc=pass header.from=evil.example"))).verified?
    refute verdict(agent_email(top_result: ses_result(dmarc: "spf=pass smtp.mailfrom=mcritchie.studio"))).verified?
  end

  test "a pass written inside a comment is not a result" do
    raw = agent_email(top_result: ses_result(dkim: "dkim=fail (dkim=pass header.i=@mcritchie.studio) header.i=@mcritchie.studio"))
    refute verdict(raw).verified?
  end

  test "a sender's lone ( or \" cannot swallow SES's next line and expose its own pass" do
    %w[( "].zip(%w[) "]).each do |open, close|
      top = "Authentication-Results: amazonses.com;\r\n spf=pass client-ip=209.85.218.70;\r\n " \
            "dkim=fail header.i=@x.mcritchie.studio#{open};\r\n dkim=fail header.i=@a#{close}dkim=pass " \
            "header.d=mcritchie.studio;\r\n dmarc=pass header.from=mcritchie.studio;\r\n"
      v = verdict(agent_email(top_result: top))
      refute v.verified?, "#{open} swallowed a line"
      assert_match(/runs across a folded line/, v.reason)
    end
  end

  test "relaxed alignment: a subdomain signature aligns, header.d is read too" do
    assert verdict(agent_email(top_result: ses_result(dkim: "dkim=pass header.d=mail.mcritchie.studio"))).verified?
    raw = agent_email(from: "Bea <bea@team.example.com>",
                      top_result: ses_result(dkim: "dkim=pass header.i=@example.com", dmarc: "dmarc=pass header.from=team.example.com"))
    assert verdict(raw).verified?
  end

  test "two From addresses are never verified" do
    refute verdict(agent_email(from: "alex@mcritchie.studio, mallory@evil.example")).verified?
  end
end
