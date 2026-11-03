require "test_helper"

class MailScore::Classifier::SamplesTest < MailScore::TestCase
  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
  end

  def teardown
    @database.close
  end

  def test_the_text_is_the_words_bayes_reads
    message = MailScore::Message.new("Subject: Cheap PILLS\nContent-Type: text/html\n\n<p>Buy <b>now</b>, don't wait!</p>")

    assert_equal "cheap pills buy now dont wait", MailScore::Classifier.text(message)
    assert_equal MailScore::Classifier::WORD_CAP, MailScore::Classifier.text(mail(Array.new(1500) { "w#{it}" }.join(" "))).split.size
  end

  def test_the_text_stops_at_the_word_that_would_pass_its_byte_cap
    text = MailScore::Classifier.text(mail("short #{"a" * 10_000} #{"b" * 10_000} tail"))

    assert_equal "hello short #{"a" * 10_000}", text
    assert_equal "hello", MailScore::Classifier.text(mail("a" * 100_000))
  end

  def test_each_learn_keeps_the_text_of_the_message
    bayes = MailScore::Bayes.new(config, @database)
    bayes.learn(mail("buy cheap viagra pills now and save big on every order"), "spam")
    bayes.learn(mail("the agenda for the quarterly project meeting budget review on tuesday is attached here with notes"), "ham")

    assert_equal [ [ "spam", "hello buy cheap viagra pills now and save big on every order" ],
      [ "ham", "hello the agenda for the quarterly project meeting budget review on tuesday is attached here with notes" ] ], rows
  end

  def test_nothing_is_kept_with_fasttext_off
    MailScore::Bayes.new(config("fasttext" => false), @database).learn(mail("buy cheap viagra pills now and save big on every order"), "spam")

    assert_empty rows
  end

  def test_relearning_moves_the_sample
    samples = MailScore::Classifier::Samples.new(config, @database)
    samples.add(mail("one two three"), "spam", "one")
    samples.add(mail("one two three"), "ham", "one")

    assert_equal [ [ "ham", "hello one two three" ] ], rows
  end

  def test_a_sample_is_keyed_as_bayes_learned_it
    bayes = MailScore::Bayes.new(config, @database)
    bayes.learn(mail("Buy CHEAP viagra pills now, and save big on every order!"), "spam")
    bayes.learn(mail("buy cheap viagra pills now and save big on every order"), "ham")

    assert_equal [ [ "ham", "hello buy cheap viagra pills now and save big on every order" ] ], rows
    assert_equal @database.execute("SELECT digest FROM bayes_learned"), @database.execute("SELECT digest FROM fasttext_samples")
  end

  def test_each_class_keeps_its_newest_up_to_the_cap
    samples = MailScore::Classifier::Samples.new(config("fasttext_min_samples" => 1, "fasttext_max_samples" => 2), @database)
    4.times { samples.add(mail("spam #{it}"), "spam", "spam #{it}") }
    samples.add(mail("ham"), "ham", "ham")

    assert_equal [ [ "ham", "hello ham" ], [ "spam", "hello spam 2" ], [ "spam", "hello spam 3" ] ], rows.sort
    assert_equal({ "spam" => 2, "ham" => 1 }, samples.counts)
  end

  def test_a_sample_expires
    samples = MailScore::Classifier::Samples.new(config("fasttext_sample_expiry" => 60), @database)
    samples.add(mail("old"), "spam", "old", now: Time.at(1000))
    samples.add(mail("new"), "spam", "new", now: Time.at(1050))

    @database.expire(now: Time.at(1060))

    assert_equal [ [ "spam", "hello new" ] ], rows
  end

  private
    def config(settings = {})
      MailScore::Config.parse(SETTINGS.merge("fasttext" => true, **settings), env: TOKENS)
    end

    def mail(text)
      MailScore::Message.new("From: a@example.org\nSubject: Hello\n\n#{text}")
    end

    def rows
      @database.execute("SELECT class, text FROM fasttext_samples ORDER BY id")
    end
end
