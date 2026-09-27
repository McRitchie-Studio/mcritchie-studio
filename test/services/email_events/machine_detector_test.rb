require "test_helper"

# [unit] Which opens and clicks count as a person's. Real user agents from the
# clients the list reads with, and the programs that fake a read.
class EmailEvents::MachineDetectorTest < ActiveSupport::TestCase
  Detector = EmailEvents::MachineDetector
  GMAIL_PROXY = "Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko Firefox/11.0 (via ggpht.com GoogleImageProxy)"
  OUTLOOK_DESKTOP = "Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17126; Pro)"
  IPHONE_SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  test "people reading in Gmail, Outlook desktop and on an iPhone count as people" do
    [GMAIL_PROXY, OUTLOOK_DESKTOP, IPHONE_SAFARI].each do |ua|
      assert_not Detector.machine?(user_agent: ua, sent_at: 1.hour.ago), ua
    end
  end

  test "Apple's privacy prefetch, a blank agent and scanners are machines" do
    ["Mozilla/5.0", "", nil, "Barracuda Sentinel (EE)", "python-requests/2.31", "Mozilla/5.0 (compatible; Googlebot/2.1)",
     "Microsoft Office Existence Discovery", "Mozilla/5.0 HeadlessChrome/120.0"].each do |ua|
      assert Detector.machine?(user_agent: ua, sent_at: 1.hour.ago), ua.inspect
    end
  end

  test "a HEAD request is a link checker" do
    assert Detector.machine?(user_agent: IPHONE_SAFARI, sent_at: 1.hour.ago, method: "HEAD")
  end

  test "anything within ten seconds of the send is too soon for a person" do
    now = Time.current
    assert Detector.machine?(user_agent: IPHONE_SAFARI, sent_at: now - 3.seconds, at: now)
    assert_not Detector.machine?(user_agent: IPHONE_SAFARI, sent_at: now - 30.seconds, at: now)
  end
end
