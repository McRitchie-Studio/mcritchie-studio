require "test_helper"

# [unit] Which CTO an email is for (AgentMessages::EmailRoutes), the new text
# it is read from (EmailBody), and the mail no agent may answer (EmailLoopGuard).
class EmailRoutesTest < ActiveSupport::TestCase
  def routes = AgentMessages::EmailRoutes.load

  def route(to: [ "team@mcritchie.studio" ], cc: [], subject: "", text: "")
    routes.route(to: to, cc: cc, subject: subject, text: text)
  end

  # --- routing -------------------------------------------------------------

  test "a CTO's own address routes to it, in To or Cc" do
    assert_equal [ "avi", "alias" ], route(to: [ "avi@mcritchie.studio" ]).to_h.values_at(:soul, :routed_by)
    assert_equal "avi", route(to: [ "someone@example.com" ], cc: [ "AVI@mcritchie.studio" ]).soul
  end

  test "a mail to team@ that addresses a CTO by name in the subject or first line routes to it" do
    assert_equal "avi", route(subject: "Avi: what is on QA?").soul
    assert_equal "avi", route(subject: "Re: Fwd: Avi, release status").soul
    assert_equal "avi", route(text: "\n\nHi Avi, is the release green?\nthanks").soul
    assert_equal "avi", route(text: "@Avi what shipped this week").soul
    assert_equal "turf_monster", route(text: "Turf: how many signups today?").soul
    assert_equal "name", route(text: "Hey avi: hi").routed_by
  end

  test "a name that is not an address does not route" do
    [ "Turf scores look off this week", "Avid readers", "Talked to Avi today", "Avi" ].each do |line|
      refute route(subject: line, text: line).routed?, line
    end
    refute route(text: "Hello team,\nAvi, can you look?").routed?, "only the FIRST non-blank line counts"
  end

  test "the name rule needs team@ among the recipients" do
    refute route(to: [ "alex@example.com" ], subject: "Avi: status").routed?
  end

  test "the fleet's own addresses are known, and each soul has a sender" do
    r = routes
    %w[avi@mcritchie.studio team@mcritchie.studio carl@mcritchie.studio team@turfmonster.media].each do |addr|
      assert r.agent_address?(addr), addr
    end
    refute r.agent_address?("alex@mcritchie.studio")
    assert_equal "Avi <avi@mcritchie.studio>", r.from_for("avi")
    assert_equal "avi@mcritchie.studio", r.address_for("avi")
    assert_equal "team@mcritchie.studio", r.address_for("turf_monster")
  end

  # --- the new text --------------------------------------------------------

  test "the new text drops the quoted history, the wrote line, and the signature" do
    body = "go\r\n\r\nOn Fri, Oct 16, 2026 at 1:15 PM Avi <avi@mcritchie.studio> wrote:\r\n> Proposed: count\r\n> Reply go"
    assert_equal "go", AgentMessages::EmailBody.new_text(body)
    wrapped = "no\n\nOn Fri, Oct 16, 2026 at 1:15 PM Avi\n<avi@mcritchie.studio> wrote:\n> old"
    assert_equal "no", AgentMessages::EmailBody.new_text(wrapped)
    assert_equal "go", AgentMessages::EmailBody.new_text("go\n\nSent from my iPhone")
    assert_equal "change: 3 days", AgentMessages::EmailBody.new_text("change: 3 days\n-- \nAlex\n")
    outlook = "Looks good\n________________________________\nFrom: Avi <avi@mcritchie.studio>\nSent: Friday"
    assert_equal "Looks good", AgentMessages::EmailBody.new_text(outlook)
    assert_equal "Line one\nLine two", AgentMessages::EmailBody.new_text("Line one\nLine two\n> quoted")
  end

  # --- loop guards -----------------------------------------------------------

  def guard(headers, from: "alex@mcritchie.studio")
    AgentMessages::EmailLoopGuard.new(routes: routes).reason(headers, from: from)
  end

  test "an ordinary mail passes the loop guards" do
    assert_nil guard([ %w[Return-Path <alex@mcritchie.studio>], %w[Content-Type text/plain] ])
  end

  test "our own outbound, and any mail from a fleet address, is never answered" do
    assert_match(/our own outbound/, guard([ %w[X-McRitchie-Agent avi] ]))
    assert_match(/never a CTO to a CTO/, guard([], from: "avi@mcritchie.studio"))
    assert_match(/never a CTO to a CTO/, guard([], from: "team@mcritchie.studio"))
    assert_match(/never a CTO to a CTO/, guard([], from: "team@turfmonster.media"))
  end

  test "auto replies, lists and bulk mail are never answered" do
    assert_match(/auto-submitted/, guard([ %w[Auto-Submitted auto-replied] ]))
    assert_nil guard([ %w[Auto-Submitted no] ])
    assert_match(/X-Autoreply/, guard([ %w[X-Autoreply yes] ]))
    assert_match(/mailing list/, guard([ [ "List-Id", "Weekly News <news.example.com>" ] ]))
    assert_match(/bulk mail/, guard([ %w[Precedence bulk] ]))
    assert_match(/bulk mail/, guard([ %w[Precedence list] ]))
  end

  test "our own Google group's List-Id is not an outside list" do
    assert_nil guard([ [ "List-Id", "<team.mcritchie.studio>" ], %w[Precedence list] ])
    assert_match(/bulk/, guard([ [ "List-Id", "<team.mcritchie.studio>" ], %w[Precedence bulk] ]))
  end

  test "bounces and mailer daemons are never answered" do
    assert_match(/mailer daemon/, guard([], from: "MAILER-DAEMON@amazonses.com"))
    assert_match(/mailer daemon/, guard([], from: "no-reply@example.com"))
    assert_match(/mailer daemon/, guard([], from: "postmaster@example.com"))
    assert_match(/null Return-Path/, guard([ [ "Return-Path", "<>" ] ]))
    assert_match(/delivery report/, guard([ [ "Content-Type", "multipart/report; report-type=delivery-status" ] ]))
  end
end
