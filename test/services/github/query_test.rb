require "test_helper"

class Github::QueryTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:url, :status, :headers, :body, keyword_init: true)

  test "runs raw commit search through github client response inspection" do
    requests = []
    response = Github::Query.new(client: fake_client(requests)).commit_search(q: "author:amcritchie", per_page: 3)

    assert_equal 200, response.status
    assert_equal "/search/commits", requests.first.fetch(:path)
    assert_equal({ q: "author:amcritchie", per_page: 3 }, requests.first.fetch(:params))
    assert_equal "application/vnd.github+json", requests.first.fetch(:headers).fetch("Accept")
  end

  test "builds username author commit search query for date segment" do
    requests = []

    Github::Query.new(client: fake_client(requests)).commits_for_login(
      "amcritchie",
      start_date: Date.new(2024, 1, 20),
      end_date: Date.new(2024, 4, 19),
      role: :author
    )

    assert_equal(
      "author:amcritchie author-date:2024-01-20..2024-04-19 merge:false is:public",
      requests.first.dig(:params, :q)
    )
  end

  test "builds email committer commit search query for date segment" do
    requests = []

    Github::Query.new(client: fake_client(requests)).commits_for_email(
      "alex@planomatic.com",
      start_date: "2024-01-20",
      end_date: "2024-04-19",
      role: :committer,
      per_page: 10
    )

    assert_equal(
      "committer-email:alex@planomatic.com committer-date:2024-01-20..2024-04-19 merge:false is:public",
      requests.first.dig(:params, :q)
    )
    assert_equal 10, requests.first.dig(:params, :per_page)
  end

  test "rejects unsupported roles" do
    error = assert_raises(ArgumentError) do
      Github::Query.new(client: fake_client([])).commits_for_login(
        "amcritchie",
        start_date: "2024-01-20",
        end_date: "2024-04-19",
        role: :reviewer
      )
    end

    assert_includes error.message, "role must be"
  end

  private

  def fake_client(requests)
    Class.new do
      define_method(:initialize) { |requests| @requests = requests }

      define_method(:get_response) do |path, params:, headers:|
        @requests << { path: path, params: params, headers: headers }
        FakeResponse.new(url: "https://api.github.com/search/commits", status: 200, headers: {}, body: {})
      end
    end.new(requests)
  end
end
