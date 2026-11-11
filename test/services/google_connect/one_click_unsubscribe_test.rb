require "test_helper"

# [unit] GoogleConnect::OneClickUnsubscribe (/tasks/gmail-one-click-unsubscribe):
# how each List-Unsubscribe header shape is classified, and the fence around
# the one POST it sends (https only, public addresses only, no redirect, no
# token or cookie). Stand-ins replace DNS and the network; no test leaves the box.
class GoogleConnect::OneClickUnsubscribeTest < ActiveSupport::TestCase
  Subject = GoogleConnect::OneClickUnsubscribe

  setup do
    @posts = []
    Subject.resolver = ->(_host) { [ "93.184.216.34" ] }
    Subject.http = ->(url, ip, body) { @posts << [ url, ip, body ] && [ 200, nil ] }
  end

  teardown do
    Subject.resolver = nil
    Subject.http = nil
  end

  ONE_CLICK = "List-Unsubscribe=One-Click".freeze

  test "[unit] each header shape gets its kind" do
    {
      [ "<https://ex.com/u/1>, <mailto:u@ex.com>", ONE_CLICK ] => "one-click",
      [ "<mailto:u@ex.com>, <https://ex.com/u/1>", "list-unsubscribe=one-click" ] => "one-click",
      [ "<https://ex.com/u/1>", nil ] => "web-page",
      [ "<http://ex.com/u/1>", ONE_CLICK ] => "web-page",
      [ "<http://ex.com/u/1>", nil ] => "web-page",
      [ "<mailto:u@ex.com?subject=unsubscribe>", ONE_CLICK ] => "email-only",
      [ "<mailto:u@ex.com>", nil ] => "email-only",
      [ nil, nil ] => "none",
      [ "", ONE_CLICK ] => "none",
      [ "https://ex.com/no-brackets", ONE_CLICK ] => "none"
    }.each do |(header, post), kind|
      assert_equal kind, Subject.kind(header, post), "#{header.inspect} / #{post.inspect}"
    end
  end

  test "[unit] https_uri picks the https entry over a mailto and an http one" do
    assert_equal "https://ex.com/u/1", Subject.https_uri("<mailto:u@ex.com>, <http://ex.com/x>, <https://ex.com/u/1>")
    assert_nil Subject.https_uri("<mailto:u@ex.com>")
  end

  test "[unit] a one-click POST sends the RFC 8058 body to the checked address" do
    outcome = Subject.post("https://ex.com/u/1")

    assert outcome.ok
    assert_equal [ [ "https://ex.com/u/1", "93.184.216.34", "List-Unsubscribe=One-Click" ] ], @posts
  end

  test "[unit] the request carries the form body and content type, never a token or cookie" do
    request = Subject.new.build_request(URI("https://ex.com/u/1"))

    assert_equal "POST", request.method
    assert_equal "application/x-www-form-urlencoded", request["Content-Type"]
    assert_equal "List-Unsubscribe=One-Click", request.body
    assert_nil request["Authorization"]
    assert_nil request["Cookie"]
    assert_equal [ "url" ], Subject.instance_method(:post).parameters.map { _1.last.to_s }, "post takes the URL alone, no token"
  end

  test "[unit] http, mailto, a user in the URL and junk are refused before any POST" do
    [ "http://ex.com/u/1", "mailto:u@ex.com", "https://user:pw@ex.com/u", "not a url", "" ].each do |url|
      outcome = Subject.post(url)
      assert_not outcome.ok, url
      assert_match(/\Arefused:/, outcome.error, url)
    end
    assert_empty @posts
  end

  test "[unit] a host that resolves to a private, loopback, link-local or metadata address is refused" do
    %w[10.1.2.3 172.16.0.9 192.168.1.1 127.0.0.1 169.254.169.254 100.64.0.1 0.0.0.0 ::1 fd00:ec2::254 fe80::1 ::ffff:127.0.0.1].each do |address|
      Subject.resolver = ->(_host) { [ address ] }
      outcome = Subject.post("https://ex.com/u/1")
      assert_not outcome.ok, address
      assert_match(/private address/, outcome.error, address)
    end
    assert_empty @posts
  end

  test "[unit] one private address among public ones is enough to refuse" do
    Subject.resolver = ->(_host) { [ "93.184.216.34", "10.0.0.1" ] }

    assert_not Subject.post("https://ex.com/u/1").ok
    assert_empty @posts
  end

  test "[unit] a literal private IP in the URL is refused through the same guard" do
    Subject.resolver = nil

    outcome = Subject.post("https://127.0.0.1/u/1")
    assert_match(/private address/, outcome.error)
    outcome = Subject.post("https://[::1]/u/1")
    assert_match(/private address/, outcome.error)
    assert_empty @posts
  end

  test "[unit] a host that does not resolve is refused" do
    Subject.resolver = ->(_host) { [] }

    assert_match(/does not resolve/, Subject.post("https://nowhere.invalid/u").error)
    assert_empty @posts
  end

  test "[unit] a redirect is a failure and is not followed; an error status is a failure" do
    Subject.http = ->(url, ip, body) { @posts << [ url, ip, body ] && [ 302, nil ] }
    outcome = Subject.post("https://ex.com/u/1")
    assert_not outcome.ok
    assert_equal 302, outcome.status
    assert_match(/redirects are not followed/, outcome.error)
    assert_equal 1, @posts.size, "one POST, no second request to the Location"

    Subject.http = ->(*) { [ 500, nil ] }
    assert_equal "answered 500", Subject.post("https://ex.com/u/1").error
  end

  test "[unit] a network error comes back as a failure, never raised" do
    Subject.http = ->(*) { raise Net::OpenTimeout }

    outcome = Subject.post("https://ex.com/u/1")
    assert_not outcome.ok
    assert_match(/could not be reached: Net::OpenTimeout/, outcome.error)
  end

  test "[unit] the network path uses short timeouts and https" do
    assert_equal [ 5, 10 ], [ Subject::OPEN_TIMEOUT, Subject::READ_TIMEOUT ]
    source = Rails.root.join("app/services/google_connect/one_click_unsubscribe.rb").read
    assert_includes source, "http.use_ssl = true"
    assert_no_match(/Authorization|Cookie"|mailto:\/\/|Net::SMTP/, source.gsub(/^\s*#.*$/, "").gsub("no cookie and no Authorization", ""))
  end
end
