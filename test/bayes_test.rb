require "test_helper"

class MailScore::BayesTest < MailScore::TestCase
  SPAM = [
    "Buy cheap viagra pills now and save big money today",
    "Limited offer: buy cheap viagra pills now today with free shipping",
    "Buy cheap viagra pills now, before the offer ends this week tonight"
  ].freeze

  HAM = [
    "Here is the agenda for the quarterly project meeting budget review on Tuesday with draft minutes",
    "I moved the agenda for the quarterly project meeting budget review to Wednesday afternoon",
    "Notes from the agenda for the quarterly project meeting budget review are attached"
  ].freeze

  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @bayes = MailScore::Bayes.new(MailScore::Config.parse(SETTINGS.merge("bayes_min_learns" => 3), env: TOKENS), @database)
  end

  def teardown
    @database.close
  end

  def test_past_the_cap_the_tokens_seen_least_go
    @database.execute("INSERT INTO bayes_tokens (token, spam, ham) VALUES (1, 1, 0), (2, 3, 2), (3, 0, 1), (4, 2, 0)")
    bayes = MailScore::Bayes.new(MailScore::Config.parse(SETTINGS.merge("bayes_max_tokens" => 2), env: TOKENS), @database)

    bayes.prune

    assert_equal [ 2, 4 ], @database.execute("SELECT token FROM bayes_tokens ORDER BY token").flatten
  end

  def test_words_are_nfkc_and_lowercase
    assert_equal [ "héllo", "world", "2026", "dont", "x" * 41 ], MailScore::Bayes::Tokens.words("Héllo, WORLD! 2026 don't #{"x" * 41}")
    assert_equal %w[ fine paypal foo_bar ], MailScore::Bayes::Tokens.words("ﬁne pay​pal foo_bar")
  end

  def test_words_break_where_unicode_breaks_them
    assert_equal %w[ eg 314 1000 $ 99 e mail end next a 1 x y ],
      MailScore::Bayes::Tokens.words("e.g. 3.14 1,000 $99 e-mail end. Next a.1 x:y")
  end

  def test_words_are_stemmed_for_their_language
    assert_equal %w[ run quick 2026 ], MailScore::Bayes::Tokens.words("Running QUICKLY 2026", "en")
    assert_equal %w[ haus ], MailScore::Bayes::Tokens.words("Häuser", "de")
    assert_equal %w[ running ], MailScore::Bayes::Tokens.words("running", "ja")
    assert_equal %w[ running ], MailScore::Bayes::Tokens.words("running")
  end

  def test_stop_words_go_with_a_language
    assert_equal %w[ offer ], MailScore::Bayes::Tokens.words("The offer is for you", "en")
    assert_equal %w[ angebot ], MailScore::Bayes::Tokens.words("und das Angebot", "de")
    assert_equal %w[ running ], MailScore::Bayes::Tokens.words("the running", "ja")
    assert_equal %w[ the offer is for you ], MailScore::Bayes::Tokens.words("The offer is for you")
  end

  def test_a_stop_word_of_any_language_goes
    assert_equal %w[ offer ], MailScore::Bayes::Tokens.words("und the offer dog", "en")
    assert_equal %w[ angebot ], MailScore::Bayes::Tokens.words("the Angebot", "de")
  end

  def test_a_bigram_pairs_the_words_either_side_of_a_stop_word
    assert_equal [ "text\u00001\u0000buy\u0000pill" ], MailScore::Bayes::Tokens.bigrams("text", "buy the pills", "en").to_a
  end

  def test_stop_words_are_snowballs_stemmed_in_one_set
    assert_includes MailScore::Bayes::Tokens::STOP_WORDS, "have"
    assert_includes MailScore::Bayes::Tokens::STOP_WORDS, "und"
    refute_includes MailScore::Bayes::Tokens::STOP_WORDS, "offer"
  end

  def test_each_part_is_read_apart_in_english_by_default
    message = MailScore::Message.new(<<~MAIL)
      Subject: Running offers
      Content-Type: multipart/alternative; boundary="b"

      --b
      Content-Type: text/plain

      running birds
      --b
      Content-Type: text/plain

      jumping cats
      --b--
    MAIL

    assert_equal digests(MailScore::Bayes::Tokens.headers(message) +
      [ "subject\u00001\u0000run\u0000offer", "text\u00001\u0000run\u0000bird", "text\u00001\u0000jump\u0000cat" ]), MailScore::Bayes::Tokens.of(message)

    detector = Detector.new({ "running birds" => "ja", "jumping cats" => "ja" })
    assert_equal digests(MailScore::Bayes::Tokens.headers(message) +
      [ "subject\u00001\u0000running\u0000offers", "text\u00001\u0000running\u0000birds", "text\u00001\u0000jumping\u0000cats" ]), MailScore::Bayes::Tokens.of(message, detector)
  end

  def test_the_subject_takes_the_first_parts_language
    detector = Detector.new({ "Häuser kaufen" => "de" })

    assert_includes MailScore::Bayes::Tokens.of(mail("Häuser kaufen", subject: "Billige Häuser"), detector),
      digests([ "subject\u00001\u0000billig\u0000haus" ]).first
  end

  def test_the_language_is_the_models_most_likely
    model = Model.new([])
    language = MailScore::Bayes::Language.new(model)

    model.answers = { "de" => 0.9, "nl" => 0.05 }
    assert_equal "de", language.detect("Das Angebot,\nheute! #{"x" * 257}")
    assert_equal [ "Das Angebot heute" ], model.texts

    model.answers = {}
    assert_equal "en", language.detect("zzz")
    assert_nil language.detect(" ...\n")
  end

  def test_without_a_model_every_text_with_words_is_english
    assert_equal "en", MailScore::Bayes::Language::DEFAULT.detect("Das Angebot heute")
    assert_nil MailScore::Bayes::Language::DEFAULT.detect(" ...\n")
  end

  def test_english_is_snowballs_english_stemmer_not_porters
    assert_equal %w[ generous sky ], MailScore::Bayes::Tokens.words("generously skies", "en")
  end

  def test_without_a_model_bayes_learns_english_stems
    message = mail("The cheapest pills are here for you, shipped quickly to your home address with discreet packaging tonight", subject: "Cheapest pills")

    assert @bayes.learn(message, "spam")
    assert_equal MailScore::Bayes::Tokens.of(message).sort, @database.execute("SELECT token FROM bayes_tokens").flatten.sort
    assert_includes MailScore::Bayes::Tokens.of(message), digests([ "text\u00001\u0000ship\u0000quick" ]).first
  end

  def test_a_language_model_stems_and_drops_stop_words_as_it_learns
    text = "The cheapest pills are here for you, shipped quickly to your home address with discreet packaging tonight"
    detector = Detector.new({ text => "en" })
    message = mail(text, subject: "Cheapest pills")

    with_language_model(detector) do |bayes|
      assert bayes.learn(message, "spam")
      assert_equal MailScore::Bayes::Tokens.of(message, detector).size, @database.execute("SELECT count(*) FROM bayes_tokens").dig(0, 0)
      assert_includes MailScore::Bayes::Tokens.of(message, detector), digests([ "text\u00001\u0000cheapest\u0000pill" ]).first
    end
  end

  def test_each_part_is_detected_once_per_scan
    detector = Detector.new({ "one two three" => "en" })
    message = mail("one two three")

    3.times { MailScore::Bayes::Tokens.of(message, detector) }
    assert_equal 1, detector.detections
  end

  def test_bigrams_pair_each_word_with_the_next
    tokens = MailScore::Bayes::Tokens.bigrams("text", "a b c d").to_a

    assert_equal [ "text\u00001\u0000a\u0000b", "text\u00001\u0000b\u0000c", "text\u00001\u0000c\u0000d" ], tokens
  end

  def test_urls_give_their_first_five_registrable_domains
    links = %w[ https://www.example.com/a http://example.com/b https://mail.example.co.uk http://192.0.2.1/x
      https://one.example https://two.example https://three.example ].join(" ")

    assert_equal [ "url\u0000example.com", "url\u0000example.co.uk", "url\u0000192.0.2.1", "url\u0000one.example", "url\u0000two.example" ],
      MailScore::Bayes::Tokens.urls(mail(links))
    assert_empty MailScore::Bayes::Tokens.urls(mail("no links here"))
  end

  def test_headers_give_a_few_tokens
    message = MailScore::Message.new("From: A <a@Example.ORG>\nMessage-ID: <1@mx.example.org>\nX-Mailer: Mutt/2.2\n\nbody")

    assert_equal [ "header\u0000from\u0000example.org", "header\u0000message-id\u0000mx.example.org", "header\u0000mailer\u0000mutt",
      "header\u0000content-type\u0000text/plain" ], MailScore::Bayes::Tokens.headers(message)
  end

  def test_tokens_are_unique_64_bit_integers_up_to_the_cap
    tokens = MailScore::Bayes::Tokens.of(mail("spam spam spam spam spam spam"))

    assert_equal tokens.uniq, tokens
    assert(tokens.all? { it.is_a?(Integer) && it.bit_length < 64 })
    assert_equal 4 + 1, tokens.size

    words = Array.new(3000) { "word#{it}" }.join(" ")
    assert_equal MailScore::Bayes::Tokens::CAP, MailScore::Bayes::Tokens.of(mail(words)).size
  end

  def test_the_subject_has_its_own_tokens
    assert_empty MailScore::Bayes::Tokens.of(mail("cheap pills", subject: "x")) & MailScore::Bayes::Tokens.of(mail("x", subject: "cheap pills")) - header_tokens
  end

  def test_it_answers_only_after_enough_learns_of_each_class
    SPAM.each { @bayes.learn(mail(it), "spam") }
    HAM.first(2).each { @bayes.learn(mail(it), "ham") }
    assert_nil @bayes.probability(mail(SPAM.first))

    @bayes.learn(mail(HAM.last), "ham")
    refute_nil @bayes.probability(mail(SPAM.first))
  end

  def test_a_small_corpus_classifies_right
    train

    assert_operator @bayes.probability(mail("Buy cheap viagra pills now and save big money today, tonight")), :>, 0.9
    assert_operator @bayes.probability(mail("See the agenda for the quarterly project meeting budget review on Tuesday")), :<, 0.1
  end

  def test_tokens_seen_too_rarely_are_ignored
    train
    @bayes.learn(mail("zebra quokka narwhal okapi axolotl pangolin tapir ibex", subject: "Offer"), "spam")

    assert_equal 0.5, @bayes.probability(mail("zebra quokka narwhal okapi axolotl pangolin tapir ibex", subject: "unseen", from: "x@unseen.example"))
  end

  def test_tokens_leaning_a_little_are_dropped_and_tokens_at_even_kept
    train
    probe = mail("common words appear everywhere in all mail sent daily across offices", subject: "unseen thing", from: "x@unseen.example")
    counts = ->(spam, ham) { MailScore::Bayes::Tokens.of(probe).each { @database.execute("INSERT OR REPLACE INTO bayes_tokens VALUES (?, ?, ?)", it, spam, ham) } }

    counts.(5, 5)
    assert_equal 0.5, @bayes.probability(probe)
    counts.(6, 5)
    assert_nil @bayes.probability(probe)
    counts.(5, 6)
    assert_nil @bayes.probability(probe)
    counts.(8, 2)
    assert_operator @bayes.probability(probe), :>, 0.5
  end

  def test_a_long_message_does_not_underflow
    train
    probability = @bayes.probability(mail("buy cheap viagra pills now save big " * 300))

    assert_operator probability, :>, 0.9
    assert_operator probability, :<=, 1.0
  end

  def test_a_message_with_too_few_tokens_is_neither_learned_nor_classified
    train
    short, enough = mail("Buy cheap viagra pills now and save big"), mail("Buy cheap viagra pills now and save big money")

    assert_equal [ 10, 11 ], [ short, enough ].map { MailScore::Bayes::Tokens.of(it).size }
    assert_nil @bayes.probability(short)
    refute_nil @bayes.probability(enough)
    assert_nil @bayes.learn(short, "spam")
    assert_equal [ [ "ham", 3 ], [ "spam", 3 ] ], @database.execute("SELECT class, learns FROM bayes_totals ORDER BY class")
    assert @bayes.learn(enough, "ham")
  end

  def test_a_learn_is_heard_however_sure_the_classifier_already_is
    train
    message = mail("Buy cheap viagra pills now and save big today, really")

    assert_operator @bayes.probability(message), :>, 0.9
    assert @bayes.learn(message, "spam")
    assert @bayes.learn(mail("See the agenda for the quarterly project meeting on Tuesday with budget notes"), "spam")
  end

  def test_learning_counts_tokens_and_learns
    assert @bayes.learn(mail(SPAM.first), "spam")

    assert_equal [ [ "spam", 1 ] ], @database.execute("SELECT class, learns FROM bayes_totals")
    assert_equal [ [ 1, 0 ] ], @database.execute("SELECT DISTINCT spam, ham FROM bayes_tokens")
    assert_equal MailScore::Bayes::Tokens.of(mail(SPAM.first)).size, @database.execute("SELECT count(*) FROM bayes_tokens").dig(0, 0)
  end

  def test_the_same_class_again_is_already_learned
    @bayes.learn(mail(SPAM.first), "spam")

    refute @bayes.learn(mail(SPAM.first), "spam")
    assert_equal [ [ "spam", 1 ] ], @database.execute("SELECT class, learns FROM bayes_totals")
  end

  def test_a_message_is_known_by_its_tokens
    @bayes.learn(mail(SPAM.first), "spam")

    refute @bayes.learn(MailScore::Message.new("X-Spam: Yes\n#{mail(SPAM.first).raw}"), "spam")
    refute @bayes.learn(mail("BUY cheap viagra pills, now, and save BIG money today!!!"), "spam")
    assert @bayes.learn(mail(SPAM.first, subject: "Another offer"), "spam")
    assert_includes @database.execute("SELECT digest FROM bayes_learned").flatten,
      Digest::SHA256.hexdigest(MailScore::Bayes::Tokens.of(mail(SPAM.first)).pack("q>*"))
  end

  def test_the_other_class_moves_the_counts
    @bayes.learn(mail(SPAM.first), "spam")

    assert @bayes.learn(mail(SPAM.first), "ham")
    assert_equal [ [ "ham", 1 ], [ "spam", 0 ] ], @database.execute("SELECT class, learns FROM bayes_totals ORDER BY class")
    assert_equal [ [ 0, 1 ] ], @database.execute("SELECT DISTINCT spam, ham FROM bayes_tokens")
    assert_equal [ [ "ham" ] ], @database.execute("SELECT class FROM bayes_learned")
  end

  def test_autolearn_is_off_by_default
    assert_nil @bayes.autolearn(mail(SPAM.first), envelope, verdict(20))
    assert_empty @database.execute("SELECT * FROM bayes_learned")
  end

  def test_autolearn_learns_by_score
    bayes = autolearning

    assert_equal "spam", bayes.autolearn(mail(SPAM.first), envelope, verdict(12))
    assert_equal "ham", bayes.autolearn(mail(HAM.first), envelope, verdict(-2))
    assert_nil bayes.autolearn(mail(HAM.last), envelope, verdict(5))
    assert_nil bayes.autolearn(mail(SPAM.first), envelope, verdict(12))
    assert_equal [ [ "ham" ], [ "spam" ] ], @database.execute("SELECT class FROM bayes_learned ORDER BY class")
  end

  def test_autolearn_skips_trusted_senders_and_incomplete_scans
    bayes = autolearning

    assert_nil bayes.autolearn(mail(SPAM.first), envelope("HTTP_IP" => "10.0.0.1"), verdict(12))
    assert_nil bayes.autolearn(mail(SPAM.first), envelope("HTTP_USER" => "alice"), verdict(12))
    assert_nil bayes.autolearn(mail(SPAM.first), envelope, verdict(12, complete: false))
    assert_empty @database.execute("SELECT * FROM bayes_learned")
  end

  def test_autolearn_skips_a_greylisted_attempt_and_learns_its_retry
    bayes = autolearning
    greylisted = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted")
    passed = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "pass")

    assert_nil bayes.autolearn(mail(SPAM.first), envelope, verdict(12, hits: [ greylisted ]))
    assert_empty @database.execute("SELECT * FROM bayes_learned")
    assert_equal "spam", bayes.autolearn(mail(SPAM.first), envelope, verdict(12, hits: [ passed ]))
  end

  def test_autolearn_skips_what_bayes_already_called_that_class
    bayes = autolearning

    assert_nil bayes.autolearn(mail(SPAM.first), envelope, verdict(12, hits: [ MailScore::Rules::Bayes.hit(0.99) ]))
    assert_nil bayes.autolearn(mail(SPAM.first), envelope, verdict(12, hits: [ MailScore::Rules::Bayes.hit(0.65) ]))
    assert_nil bayes.autolearn(mail(HAM.first), envelope, verdict(-3, hits: [ MailScore::Rules::Bayes.hit(0.35) ]))
    assert_equal "spam", bayes.autolearn(mail(SPAM.first), envelope, verdict(12, hits: [ MailScore::Rules::Bayes.hit(0.01) ]))
    assert_equal "ham", bayes.autolearn(mail(HAM.first), envelope, verdict(-3, hits: [ MailScore::Rules::Bayes.hit(0.99) ]))
  end

  def test_the_tail_matches_known_values
    tail = ->(x, degrees) { @bayes.send(:chi_square_tail, x, degrees) }

    assert_in_delta Math.exp(-1), tail[2, 2]
    assert_in_delta 3 * Math.exp(-2), tail[4, 4]
    assert_equal 1.0, tail[0, 10]
    assert_in_delta 0.5, tail[3999.0, 4000], 0.01
  end

  private
    def train
      SPAM.each { @bayes.learn(mail(it, subject: "Offer"), "spam") }
      HAM.each { @bayes.learn(mail(it, subject: "Meeting"), "ham") }
    end

    def mail(text, subject: "Hello", from: "someone@example.org")
      MailScore::Message.new("From: #{from}\nSubject: #{subject}\n\n#{text}")
    end

    def autolearning
      settings = SETTINGS.merge("bayes_min_learns" => 3, "autolearn" => true, "autolearn_spam_score" => 10, "autolearn_ham_score" => -1)
      MailScore::Bayes.new(MailScore::Config.parse(settings, env: TOKENS), @database)
    end

    def envelope(headers = { "HTTP_IP" => "203.0.113.9" })
      MailScore::Envelope.read(headers, mail(""), local_networks: [ IPAddr.new("10.0.0.0/8") ])
    end

    def verdict(score, complete: true, hits: [])
      MailScore::Verdict.new(action: "no_action", score:, complete:, hits:, subject: nil)
    end

    def header_tokens
      MailScore::Bayes::Tokens.of(mail(""))
    end

    def digests(tokens)
      tokens.map { Digest::SHA256.digest(it).unpack1("q>") }
    end

    # Names the language of each text it is given, nil for any other, and
    # counts how often it was asked.
    Detector = Struct.new(:languages, :detections) do
      def detect(text)
        self.detections = detections.to_i + 1
        languages[text.strip]
      end
    end

    # Stands in for a fastText model, keeping the texts it was given.
    Model = Struct.new(:texts, :answers) do
      def predict(text)
        texts << text
        answers
      end
    end

    # A Bayes whose language_model path is already loaded as +detector+.
    def with_language_model(detector)
      models = MailScore::Bayes::Language.instance_variable_get(:@models)
      models["stub.ftz"] = detector
      yield MailScore::Bayes.new(MailScore::Config.parse(SETTINGS.merge("bayes_min_learns" => 3, "language_model" => "stub.ftz"), env: TOKENS), @database)
    ensure
      models.delete("stub.ftz")
    end
end
