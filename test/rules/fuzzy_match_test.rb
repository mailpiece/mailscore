require "test_helper"
require "rack/mock_request"
require_relative "../fuzzy_test"

class MailScore::Rules::FuzzyMatchTest < MailScore::TestCase
  OFFER = MailScore::FuzzyTest::OFFER

  def setup
    @config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(Dir.mktmpdir, "mailscore.sqlite3")), env: TOKENS)
    @database = MailScore::Database.new(@config.database, busy_timeout: @config.database_busy_timeout).tap(&:prepare)
    @fuzzy = MailScore::Fuzzy.new(@config, @database)
    @rule = MailScore::Rules::FuzzyMatch.new(@config, @database)
  end

  def teardown
    @database.close
  end

  def test_the_weight_grows_with_the_count_towards_the_hits_limit
    weights = [ 1, 4, 15, 20 ].map do |adds|
      adds.times { @fuzzy.add(mail(OFFER), "spam") }
      run_rule(OFFER).first.weight
    end

    assert_equal [ 1.62, 7.09, 11.9, 12.0 ], weights
    assert_equal [ MailScore::Hit.new(name: "FUZZY_SPAM", weight: 12.0, detail: "count 40, similarity 1.0") ], run_rule(OFFER)
  end

  def test_the_weight_scales_with_similarity_above_a_half
    20.times { @fuzzy.add(mail(OFFER), "spam") }
    hit, = run_rule(OFFER.sub("Dear customer", "Dear friend"))
    similarity = hit.detail[/similarity (\S+)/, 1].to_f

    assert_operator similarity, :<, 1.0
    assert_equal (12 * Math.tanh(Math::E) * (similarity - 0.5) / 0.5).round(2), hit.weight
  end

  def test_each_flag_fires_its_own_symbol
    @fuzzy.add(mail(OFFER), "spam")
    @fuzzy.add(mail(OFFER), "prob")
    @fuzzy.add(mail(OFFER), "ham")

    assert_equal [ [ "FUZZY_HAM", -1.84 ], [ "FUZZY_PROBABLE_SPAM", 1.33 ], [ "FUZZY_SPAM", 1.62 ] ], run_rule(OFFER).map { [ it.name, it.weight ] }.sort
  end

  def test_no_match_fires_nothing
    assert_empty run_rule(OFFER)
  end

  def test_check_runs_the_rule
    @fuzzy.add(mail(OFFER), "spam")
    app = MailScore::App.new(@config, database: @database, rules: [ MailScore::Rules::FuzzyMatch ])
    response = Rack::MockRequest.new(app).post("/check", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000", input: "Subject: hello\n\n#{OFFER}")

    assert_equal [ "FUZZY_SPAM" ], JSON.parse(response.body)["symbols"].map { it["name"] }
  end

  def test_check_describes_a_configured_flag_as_symbols_does
    flags = { "phish" => { "symbol" => "FUZZY_PHISH", "weight" => 8.5 } }
    config = MailScore::Config.parse(SETTINGS.merge("fuzzy_flags" => flags), env: TOKENS)
    MailScore::Fuzzy.new(config, @database).add(mail(OFFER), "phish")
    app = MailScore::App.new(config, database: @database, rules: [ MailScore::Rules::FuzzyMatch ])
    response = Rack::MockRequest.new(app).post("/check", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000", input: "Subject: hello\n\n#{OFFER}")

    assert_equal [ "Matches mail flagged phish" ], JSON.parse(response.body)["symbols"].map { it["description"] }
  end

  def test_the_default_flags_list_the_default_symbols
    assert_equal MailScore::Rules::FuzzyMatch::SYMBOLS, MailScore::Rules::FuzzyMatch.symbols(@config)
  end

  def test_symbols_lists_the_configured_flags
    flags = { "spam" => { "symbol" => "FUZZY_SPAM", "weight" => 9 }, "phish" => { "symbol" => "FUZZY_PHISH", "weight" => 8.5 } }
    config = MailScore::Config.parse(SETTINGS.merge("fuzzy_flags" => flags), env: TOKENS)
    app = MailScore::App.new(config, database: @database, rules: [ MailScore::Rules::FuzzyMatch ])
    response = Rack::MockRequest.new(app).get("/symbols", "HTTP_AUTHORIZATION" => "Bearer read-token-000000000000000000000")

    assert_equal [ { "name" => "FUZZY_SPAM", "weight" => 9, "description" => "Matches known spam" },
      { "name" => "FUZZY_PHISH", "weight" => 8.5, "description" => "Matches mail flagged phish" } ],
      JSON.parse(response.body).select { it["name"].start_with?("FUZZY_") }
  end

  private
    def mail(text)
      MailScore::Message.new("Subject: hello\n\n#{text}")
    end

    def run_rule(text)
      @rule.run(mail(text), nil)
    end
end
