require "test_helper"

class MailScore::Classifier::TrainerTest < MailScore::TestCase
  SPAM_WORDS = %w[ viagra winner prize cash free click offer cheap pills casino bonus urgent lottery claim ].freeze
  HAM_WORDS = %w[ meeting report invoice project lunch tomorrow agenda review draft team schedule notes budget call ].freeze
  COMMON = %w[ the a to and of you your for is in on with this that please ].freeze

  def setup
    @dir = Dir.mktmpdir
    @database = MailScore::Database.new(File.join(@dir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), "fasttext" => true,
      "fasttext_min_samples" => 20, "fasttext_max_samples" => 100), env: TOKENS)
    @trainer = MailScore::Classifier::Trainer.new(@config, @database)
    @random = Random.new(1)
  end

  def teardown
    @database.close
  end

  def test_it_waits_for_the_minimum_of_each_class
    learn(40, "spam")
    learn(19, "ham")

    refute @trainer.due?
    assert_nil @trainer.train
    refute File.exist?(@config.fasttext_model)
    assert_empty @database.execute("SELECT * FROM fasttext_trainings")
  end

  def test_it_needs_both_classes_outside_the_held_out_fifth
    @config = @config.with(fasttext_min_samples: 1)
    learn(4, "spam")
    learn(1, "ham")

    assert_nil MailScore::Classifier::Trainer.new(@config, @database).train
  end

  def test_it_trains_on_the_samples_and_judges_on_the_held_out_fifth
    learn(40, "spam")
    learn(40, "ham")

    training = @trainer.train(now: Time.at(1_000_000))

    assert training.swapped
    assert_equal 64, training.spam + training.ham
    assert_in_delta 1.0, training.accuracy, 0.1
    assert_nil training.previous_accuracy
    assert_equal %w[ ham spam ], FastText.load_model(@config.fasttext_model).labels.sort
    assert_equal({ "trained_at" => "1970-01-12T13:46:40Z", "accuracy" => training.accuracy, "spam_samples" => training.spam, "ham_samples" => training.ham },
      MailScore::Classifier.new(@config, @database).stats)
  end

  def test_it_is_due_again_after_a_day
    learn(20, "spam")
    learn(20, "ham")
    assert @trainer.due?(now: Time.at(1_000_000))

    @trainer.train(now: Time.at(1_000_000))

    refute @trainer.due?(now: Time.at(1_000_000 + 86_399))
    assert @trainer.due?(now: Time.at(1_000_000 + 86_400))
  end

  def test_a_worse_model_is_not_swapped_in
    learn(40, "spam")
    learn(40, "ham")
    @trainer.train(now: Time.at(1_000_000))
    before = File.stat(@config.fasttext_model)

    # Mislabel everything trained on; the held-out fifth stays right.
    @database.execute("UPDATE fasttext_samples SET class = CASE class WHEN 'spam' THEN 'ham' ELSE 'spam' END WHERE id % 5 != 0")
    training = @trainer.train(now: Time.at(1_000_100))

    refute training.swapped
    assert_operator training.accuracy, :<, training.previous_accuracy
    assert_equal before.ino, File.stat(@config.fasttext_model).ino
    assert_equal({ "trained_at" => "1970-01-12T13:48:20Z", "accuracy" => training.previous_accuracy },
      MailScore::Classifier.new(@config, @database).stats.slice("trained_at", "accuracy"))
  end

  def test_a_model_as_good_as_the_current_one_is_swapped_in
    learn(40, "spam")
    learn(40, "ham")
    @trainer.train

    training = @trainer.train

    assert training.swapped
    assert_equal training.accuracy, training.previous_accuracy
  end

  def test_a_failed_write_leaves_the_current_model_whole
    File.write(@config.fasttext_model, "current")
    broken = Object.new
    def broken.save_model(path)
      File.write(path, "half")
      raise IOError, "disk full"
    end

    assert_raises(IOError) { @trainer.send(:save, broken) }
    assert_equal "current", File.read(@config.fasttext_model)
    assert_equal [ "fasttext.bin", "mailscore.sqlite3" ], Dir.children(@dir).grep_v(/-(wal|shm)\z/).sort
  end

  private
    def learn(count, klass)
      words = klass == "spam" ? SPAM_WORDS : HAM_WORDS
      samples = MailScore::Classifier::Samples.new(@config, @database)

      count.times do |index|
        text = Array.new(@random.rand(20..60)) { @random.rand < 0.4 ? words.sample(random: @random) : COMMON.sample(random: @random) }.join(" ")
        samples.add(MailScore::Message.new("Subject: #{klass} #{index}\n\n#{text}"), klass, "#{klass} #{index}")
      end
    end
end
