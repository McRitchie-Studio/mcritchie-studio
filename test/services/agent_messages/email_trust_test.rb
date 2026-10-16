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
                      sender_headers: [ FORGED_PASS ])
    v = verdict(raw)
    refute v.verified?
    assert_match(/no dkim=pass aligned/, v.reason)
  end

  test "with SES's verdict missing, a forged amazonses.com pass in the sender's block is NOT trusted" do
    raw = agent_email(top_result: nil, sender_headers: [ FORGED_PASS ])
    v = verdict(raw)
    refute v.verified?
    assert_match(/outside the receiver's trace block/, v.reason)

    # Even when the forged line is the ONLY Authentication-Results left (the
    # relay's mx.google.com one removed too), it is the topmost and still refused:
    # the relay's ARC headers sit above it.
    alone = raw.sub(/^Authentication-Results: mx\.google\.com;.*\r\n(?:[ \t].*\r\n)*/, "")
    assert_equal 1, alone.scan(/^Authentication-Results:/).size
    v = verdict(alone)
    refute v.verified?
    assert_match(/sits below ARC-Seal, outside the receiver.s trace block/, v.reason)
  end

  test "a forged verdict above a non-trace header is refused even at the top of the raw" do
    raw = agent_email(top_result: nil, extra_top: [ "X-Forged: 1", FORGED_PASS ])
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
