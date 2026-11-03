require "test_helper"

class MailScore::Rules::FasttextTest < MailScore::TestCase
  def setup
    @dir = Dir.mktmpdir
    @database = MailScore::Database.new(File.join(@dir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @config = config("fasttext" => true)
  end

  def teardown
    @database.close
  end

  def test_spam_and_ham_are_weighted_by_confidence
    assert_equal MailScore::Hit.new(name: "FASTTEXT_SPAM", weight: 3.0, detail: "100.00%"), MailScore::Rules::Fasttext.hit(1.0)
    assert_equal MailScore::Hit.new(name: "FASTTEXT_SPAM", weight: 2.7, detail: "90.00%"), MailScore::Rules::Fasttext.hit(0.95)
    assert_equal MailScore::Hit.new(name: "FASTTEXT_HAM", weight: -2.0, detail: "100.00%"), MailScore::Rules::Fasttext.hit(0.0)
    assert_equal MailScore::Hit.new(name: "FASTTEXT_HAM", weight: -1.2, detail: "60.00%"), MailScore::Rules::Fasttext.hit(0.2)
    assert_equal MailScore::Hit.new(name: "FASTTEXT_SPAM", weight: 0.36, detail: "12.00%"), MailScore::Rules::Fasttext.hit(0.56)
  end

  def test_nothing_fires_within_five_hundredths_of_even
    assert_nil MailScore::Rules::Fasttext.hit(0.5)
    assert_nil MailScore::Rules::Fasttext.hit(0.54)
    assert_nil MailScore::Rules::Fasttext.hit(0.46)
    refute_nil MailScore::Rules::Fasttext.hit(0.551)
  end

  def test_it_is_skipped_before_the_first_model
    assert_nil run_rule("claim your free cash prize now")
  end

  def test_it_runs_on_the_trained_model
    train

    assert_equal "FASTTEXT_SPAM", run_rule("claim your free cash prize now").name
    assert_equal "FASTTEXT_HAM", run_rule("the project meeting agenda for tomorrow").name
  end

  def test_it_stays_quiet_with_fasttext_off
    train
    @config = config("fasttext" => false)

    assert_nil run_rule("claim your free cash prize now")
  end

  private
    def config(settings)
      MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), "fasttext_min_samples" => 10, **settings), env: TOKENS)
    end

    def train
      samples = MailScore::Classifier::Samples.new(@config, @database)
      20.times do |index|
        samples.add(mail("claim your free cash prize now #{index}"), "spam", "spam #{index}")
        samples.add(mail("the project meeting agenda for tomorrow #{index}"), "ham", "ham #{index}")
      end
      assert MailScore::Classifier::Trainer.new(@config, @database).train.swapped
    end

    def mail(text)
      MailScore::Message.new("From: a@example.org\nSubject: Hello\n\n#{text}")
    end

    def run_rule(text)
      message = mail(text)
      MailScore::Rules::Fasttext.new(@config, @database).run(message, MailScore::Envelope.read({}, message))
    end
end
