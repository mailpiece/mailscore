require "test_helper"

class MailScore::Rules::BayesTest < MailScore::TestCase
  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @config = MailScore::Config.parse(SETTINGS.merge("bayes_min_learns" => 2), env: TOKENS)
  end

  def teardown
    @database.close
  end

  def test_spam_and_ham_are_weighted_by_the_eighth_power_of_confidence
    assert_equal MailScore::Hit.new(name: "BAYES_SPAM", weight: 5.1, detail: "100.00%"), hit(1.0)
    assert_equal MailScore::Hit.new(name: "BAYES_SPAM", weight: 2.2, detail: "90.00%"), hit(0.95)
    assert_equal MailScore::Hit.new(name: "BAYES_HAM", weight: -3.0, detail: "100.00%"), hit(0.0)
    assert_equal MailScore::Hit.new(name: "BAYES_HAM", weight: -0.5, detail: "80.00%"), hit(0.1)
    assert_equal MailScore::Hit.new(name: "BAYES_HAM", weight: -0.05, detail: "60.00%"), hit(0.2)
    assert_equal MailScore::Hit.new(name: "BAYES_SPAM", weight: 0.0, detail: "12.00%"), hit(0.56)
  end

  def test_nothing_fires_within_five_hundredths_of_even
    assert_nil hit(0.5)
    assert_nil hit(0.54)
    assert_nil hit(0.46)
    refute_nil hit(0.551)
    refute_nil hit(0.449)
  end

  def test_it_runs_on_what_was_learned
    bayes = MailScore::Bayes.new(@config, @database)
    2.times { bayes.learn(mail("buy cheap viagra pills now and save big money #{it}"), "spam") }
    2.times { bayes.learn(mail("the agenda for the quarterly project meeting budget review on tuesday with notes #{it}"), "ham") }

    assert_equal "BAYES_SPAM", run_rule("buy cheap viagra pills now and save big money").name
    assert_equal "BAYES_HAM", run_rule("the agenda for the quarterly project meeting budget review on tuesday with notes").name
  end

  def test_it_stays_quiet_before_enough_learns
    assert_nil run_rule("buy cheap viagra pills now and save big money")
  end

  private
    def hit(probability)
      MailScore::Rules::Bayes.hit(probability)
    end

    def mail(text)
      MailScore::Message.new("From: a@example.org\nSubject: Hello\n\n#{text}")
    end

    def run_rule(text)
      message = mail(text)
      MailScore::Rules::Bayes.new(@config, @database).run(message, MailScore::Envelope.read({}, message))
    end
end
