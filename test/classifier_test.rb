require "test_helper"

class MailScore::ClassifierTest < MailScore::TestCase
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "fasttext.bin")
  end

  def test_there_is_no_model_before_the_first_training
    assert_nil MailScore::Classifier.model(@path)
  end

  def test_the_model_is_loaded_once_and_again_when_replaced
    save(%w[ spam ham ])
    first = MailScore::Classifier.model(@path)

    assert_same first, MailScore::Classifier.model(@path)

    save(%w[ ham spam ])
    second = MailScore::Classifier.model(@path)

    refute_same first, second
    assert_same second, MailScore::Classifier.model(@path)
  end

  def test_the_probability_is_of_spam
    save(%w[ spam ham ])
    config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), "fasttext" => true), env: TOKENS)
    classifier = MailScore::Classifier.new(config, nil)

    assert_operator classifier.probability(mail("Subject: cash prize\n\nclaim your free cash prize now")), :>, 0.9
    assert_operator classifier.probability(mail("Subject: agenda\n\nthe project meeting agenda for tomorrow")), :<, 0.1
    assert_nil classifier.probability(mail("Subject: \n\n"))
  end

  def test_a_label_in_the_text_is_only_a_word
    assert_equal "win buy label__ham label__zz cheap", MailScore::Classifier.text(mail("Subject: win\n\nbuy __label__ham ＿＿label＿＿zz cheap ___"))
  end

  def test_a_model_that_names_neither_class_says_nothing
    save(%w[ zz yy ])
    config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), "fasttext" => true), env: TOKENS)

    assert_nil MailScore::Classifier.new(config, nil).probability(mail("Subject: cash prize\n\nclaim your free cash prize now"))
  end

  private
    # Trains a tiny model whose first label is +labels.first+ and renames it
    # into place, as a training does.
    def save(labels)
      x = [ "claim your free cash prize now", "the project meeting agenda for tomorrow" ] * 20
      model = FastText::Classifier.new(**MailScore::Classifier::Trainer::OPTIONS, min_count: 1)
      model.fit(x, labels * 20)
      model.save_model("#{@path}.tmp")
      File.rename("#{@path}.tmp", @path)
    end

    def mail(raw)
      MailScore::Message.new(raw)
    end
end
