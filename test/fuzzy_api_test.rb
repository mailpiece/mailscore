require "test_helper"
require "rack/mock_request"
require_relative "fuzzy_test"

class MailScore::FuzzyApiTest < MailScore::TestCase
  OFFER = MailScore::FuzzyTest::OFFER

  def setup
    @config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(Dir.mktmpdir, "mailscore.sqlite3")), env: TOKENS)
    @database = MailScore::Database.new(@config.database, busy_timeout: @config.database_busy_timeout).tap(&:prepare)
    @app = MailScore::App.new(@config, database: @database, rules: [])
  end

  def teardown
    @database.close
  end

  def test_add_check_and_delete
    response = post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam")
    assert_equal 200, response.status
    assert_equal({ "hashes" => 1 }, JSON.parse(response.body))
    post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam")

    response = post("/fuzzy/check", raw(OFFER.sub("Dear customer", "Dear friend")))
    assert_equal 200, response.status
    match, = JSON.parse(response.body)["matches"]
    assert_equal [ "spam", 2 ], match.values_at("flag", "count")
    assert_operator match["similarity"], :>=, 0.7

    assert_equal({ "hashes" => 1 }, JSON.parse(post("/fuzzy/delete", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam").body))
    assert_equal({ "matches" => [] }, JSON.parse(post("/fuzzy/check", raw(OFFER)).body))
  end

  def test_add_and_delete_need_the_write_token
    %w[ /fuzzy/add /fuzzy/delete ].each do |path|
      response = post(path, raw(OFFER), token: "read-token-000000000000000000000", flag: "spam")

      assert_equal 401, response.status
      assert_equal({ "error" => "unauthorized" }, JSON.parse(response.body))
    end
    assert_equal 200, post("/fuzzy/check", raw(OFFER), token: "read-token-000000000000000000000").status
  end

  def test_an_unknown_or_missing_flag_is_refused
    [ "phish", nil ].each do |flag|
      response = post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag:)

      assert_equal 422, response.status
      assert_equal({ "error" => "unknown_flag" }, JSON.parse(response.body))
    end
  end

  def test_a_weight_adds_that_many_to_the_count
    assert_equal 200, post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam", weight: " 5 ").status
    post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam")

    assert_equal [ 6 ], JSON.parse(post("/fuzzy/check", raw(OFFER)).body)["matches"].map { it["count"] }
  end

  def test_a_weight_that_is_not_a_positive_whole_number_counts_as_one
    [ "0", "-3", "1.5", "ten", "1000000000" ].each do |weight|
      assert_equal 200, post("/fuzzy/add", raw(OFFER), token: "write-token-00000000000000000000", flag: "spam", weight:).status
    end

    assert_equal [ 5 ], JSON.parse(post("/fuzzy/check", raw(OFFER)).body)["matches"].map { it["count"] }
  end

  def test_an_empty_body_is_malformed
    assert_equal 400, post("/fuzzy/add", "", token: "write-token-00000000000000000000", flag: "spam").status
    assert_equal 400, post("/fuzzy/check", "").status
  end

  private
    def raw(text)
      "Subject: hello\n\n#{text}"
    end

    def post(path, raw, token: "read-token-000000000000000000000", flag: nil, weight: nil)
      headers = { "HTTP_AUTHORIZATION" => "Bearer #{token}", input: raw, "CONTENT_TYPE" => "message/rfc822" }
      headers["HTTP_FLAG"] = flag if flag
      headers["HTTP_WEIGHT"] = weight if weight
      Rack::MockRequest.new(@app).post(path, headers)
    end
end
