require "test_helper"

class MailScore::ScannerTest < MailScore::TestCase
  def self.rule(name, weight, group = "hfilter")
    Class.new(MailScore::Rule) do
      const_set(:NAME, name)
      const_set(:GROUP, group)
      const_set(:WEIGHT, weight)
      const_set(:DESCRIPTION, "Fires on #{name}")
      define_method(:run) { |message, _envelope| MailScore::Hit.new(name:, weight:) if message.subject.to_s.include?(name) }
    end
  end

  RULES = [ rule("FIVE", 5), rule("TWO", 2), rule("TEN", 10), rule("MINUS", -0.1) ].freeze

  class SlowRule < MailScore::Rule
    NAME = "SLOW"
    GROUP = "hfilter"
    WEIGHT = 1
    DESCRIPTION = "Takes its time"

    def run(_message, _envelope)
      sleep 0.1
      nil
    end
  end

  class PatientRule < MailScore::Rule
    NAME = "PATIENT"
    GROUP = "hfilter"
    WEIGHT = 1
    DESCRIPTION = "Reports the time left"

    def run(_message, envelope)
      MailScore::Hit.new(name: NAME, weight: WEIGHT, detail: envelope.remaining)
    end
  end

  class PairRule < MailScore::Rule
    NAME = "PAIR"
    GROUP = "hfilter"
    SYMBOLS = { "LEFT" => [ 1, "Left" ], "RIGHT" => [ 2, "Right" ] }.freeze

    def run(_message, _envelope)
      [ MailScore::Hit.new(name: "LEFT", weight: 1), MailScore::Hit.new(name: "RIGHT", weight: 2) ]
    end
  end

  class HalfRule < MailScore::Rule
    NAME = "HALF"
    GROUP = "hfilter"
    WEIGHT = 4
    DESCRIPTION = "Fires at half its weight"

    def run(_message, _envelope)
      MailScore::Hit.new(name: NAME, weight: WEIGHT / 2.0)
    end
  end

  class StoredRule < MailScore::Rule
    NAME = "STORED"
    GROUP = "hfilter"
    WEIGHT = 0
    DESCRIPTION = "Reads the config and the database"

    def run(_message, _envelope)
      MailScore::Hit.new(name: NAME, weight: WEIGHT, detail: [ @config.scan_budget, @database.execute("SELECT 1").dig(0, 0) ])
    end
  end

  class FailingRule < MailScore::Rule
    NAME = "FAILING"
    GROUP = "hfilter"
    WEIGHT = 1
    DESCRIPTION = "Raises"

    def run(_message, _envelope)
      raise Regexp::TimeoutError, "regexp match timeout"
    end
  end

  class ForcingRule < MailScore::Rule
    NAME = "FORCING"
    GROUP = "test"
    WEIGHT = 0
    DESCRIPTION = "Forces reject"

    def run(message, _envelope)
      MailScore::Hit.new(name: NAME, weight: WEIGHT, data: { action: "reject" }) if message.subject.to_s.include?(NAME)
    end
  end

  class Greylister
    def initialize(answer)
      @answer = answer
    end

    def greylist(_message, _envelope, _action)
      @answer
    end
  end

  def setup
    @database = MailScore::Database.new(File.join(Dir.mktmpdir, "mailscore.sqlite3"), busy_timeout: 5).tap(&:prepare)
    @stats = MailScore::Stats.new(@database)
  end

  def teardown
    @database.close
  end

  def test_the_score_is_the_sum_of_the_fired_weights
    verdict = check("FIVE TWO MINUS")

    assert_equal 6.9, verdict.score
    assert_equal %w[ FIVE TWO MINUS ], verdict.hits.map(&:name)
    assert verdict.complete
  end

  def test_the_action_is_the_highest_threshold_reached
    assert_equal "no_action", check("TWO").action
    assert_equal "add_header", check("FIVE TWO").action
    assert_equal "reject", check("FIVE TEN").action
  end

  def test_an_action_switched_off_is_skipped
    actions = { "greylist" => false, "add_header" => 6, "rewrite_subject" => 7, "soft_reject" => false, "reject" => 30 }

    assert_equal "rewrite_subject", check("FIVE TEN", actions:).action
    assert_equal "no_action", check("FIVE", actions:).action
  end

  def test_a_hit_can_force_an_action_the_operator_left_on
    verdict = check("FORCING MINUS", rules: [ ForcingRule, *RULES ], greylister: Greylister.new([ "soft_reject", nil ]))

    assert_equal [ "reject", -0.1 ], [ verdict.action, verdict.score ]
    assert_equal "no_action", check("FORCING", rules: [ ForcingRule ], actions: { "reject" => false }).action
    assert_equal "add_header", check("FORCING FIVE TWO", rules: [ ForcingRule, *RULES ], actions: { "reject" => false }).action
    assert_equal "no_action", check("FORCING", rules: [ ForcingRule ], scores: { "FORCING" => false }).action
  end

  def test_without_a_greylister_greylist_falls_to_no_action
    verdict = check("FIVE")

    assert_equal "no_action", verdict.action
    assert_equal 5.0, verdict.score
  end

  def test_a_greylister_answers_from_the_greylist_threshold_up
    hit = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted")
    verdict = check("FIVE", greylister: Greylister.new([ "soft_reject", hit ]))

    assert_equal "soft_reject", verdict.action
    assert_equal %w[ FIVE GREYLISTED ], verdict.hits.map(&:name)
    assert_equal "soft_reject", check("FIVE TWO", greylister: Greylister.new([ "soft_reject", hit ])).action
    assert_equal "reject", check("FIVE TEN", greylister: Greylister.new([ "soft_reject", hit ])).action
  end

  def test_a_greylister_stepping_aside_keeps_the_action
    assert_equal "no_action", check("FIVE", greylister: Greylister.new(nil)).action
    assert_equal "add_header", check("FIVE TWO", greylister: Greylister.new(nil)).action
  end

  def test_a_pass_through_the_greylist_threshold_alone_is_no_action
    passed = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "pass")

    assert_equal "no_action", check("FIVE", greylister: Greylister.new([ "greylist", passed ])).action
    assert_equal "add_header", check("FIVE TWO", greylister: Greylister.new([ "add_header", passed ])).action
  end

  def test_nothing_is_greylisted_with_greylisting_off
    hit = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted")
    actions = SETTINGS["actions"].merge("greylist" => false)

    assert_equal "add_header", check("FIVE TWO", actions:, greylister: Greylister.new([ "soft_reject", hit ])).action
  end

  def test_a_verdict_is_greylisted_only_when_the_greylister_held_it_back
    held = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted")
    passed = MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "pass")

    assert_predicate check("FIVE", greylister: Greylister.new([ "soft_reject", held ])), :greylisted?
    refute_predicate check("FIVE", greylister: Greylister.new([ "no_action", passed ])), :greylisted?
    refute_predicate check("FIVE TEN", soft_reject_on_timeout: true), :greylisted?
  end

  def test_the_greylister_is_asked_only_at_the_greylist_threshold
    asked = []
    greylister = Object.new
    greylister.define_singleton_method(:greylist) do |message, _envelope, action|
      asked << [ message.subject, action ]
      nil
    end
    [ "TWO", "FIVE", "FIVE TWO", "FIVE TEN" ].each { check(it, greylister:) }
    check("FIVE TWO", greylister:, actions: SETTINGS["actions"].merge("rewrite_subject" => 7, "soft_reject" => 7))

    assert_equal [ [ "FIVE", "greylist" ], [ "FIVE TWO", "add_header" ], [ "FIVE TWO", "soft_reject" ] ], asked
  end

  def test_the_answer_has_a_reply_with_soft_reject_and_reject
    reject = check("FIVE TEN").as_json
    soft_reject = check("FIVE TEN", actions: SETTINGS["actions"].merge("soft_reject" => 14, "reject" => 20)).as_json

    assert_equal({ code: 554, enhanced: "5.7.1", text: "Spam message rejected" }, reject[:smtp_reply])
    assert_equal({ code: 451, enhanced: "4.7.1", text: "Try again later" }, soft_reject[:smtp_reply])
    assert_equal "soft reject", soft_reject[:action]
    refute check("FIVE TWO").as_json.key?(:smtp_reply)
  end

  def test_every_fixed_reply_is_well_formed
    MailScore::Verdict::REPLIES.each do |action, reply|
      assert_includes 400..599, reply[:code]
      assert_equal (action == "reject" ? "5" : "4"), reply[:code].to_s[0]
      assert_match(/\A#{reply[:code].to_s[0]}\.\d{1,3}\.\d{1,3}\z/, reply[:enhanced])
      assert_match(/\A[\x20-\x7E]{1,200}\z/, reply[:text])
    end
  end

  def test_rewrite_subject_gives_the_new_subject
    actions = SETTINGS["actions"].merge("rewrite_subject" => 6.5)

    assert_equal "*** SPAM *** FIVE TWO", check("FIVE TWO", actions:).as_json[:subject]
    assert_equal "[spam] FIVE TWO \\1 %d", check("FIVE TWO \\1 %d", actions:, subject_template: "[spam] %s").as_json[:subject]
    refute check("FIVE TWO").as_json.key?(:subject)
  end

  def test_rewrite_subject_reads_the_decoded_subject_and_encodes_what_is_not_ascii
    actions = SETTINGS["actions"].merge("rewrite_subject" => 6.5)

    assert_equal "*** SPAM *** FIVE TWO", check("=?UTF-8?B?RklWRSBUV08=?=", actions:).subject

    subject = check("=?UTF-8?Q?FIVE_TWO_caf=C3=A9=0D=0ABcc:_x@example.com?=", actions:).subject
    assert_match(/\A[\x21-\x7E]+( [\x21-\x7E]+)*\z/, subject)
    assert_equal "*** SPAM *** FIVE TWO café\r\nBcc: x@example.com", MailScore::Message.decode_words(subject)
  end

  def test_the_answer_shape
    answer = check("FIVE TWO").as_json

    assert_equal({ action: "add header", score: 7.0, complete: true, symbols: [ { name: "FIVE", weight: 5 }, { name: "TWO", weight: 2 } ] }, answer)
  end

  def test_past_the_budget_the_answer_has_the_hits_so_far
    verdict = check("FIVE TWO", rules: [ RULES[0], SlowRule, RULES[1] ], scan_budget: 0.05)

    refute verdict.complete
    assert_equal [ [ "FIVE", nil ], [ "SCAN_TIMED_OUT", "TWO" ] ], verdict.hits.map { [ it.name, it.detail ] }
    assert_equal 8.0, verdict.score
    assert_equal "add_header", verdict.action
    assert_equal false, verdict.as_json[:complete]
    assert_equal 1, @stats.to_h["budget_overruns"]
  end

  def test_a_cap_the_message_reached_fires_after_the_rules
    config = MailScore::Config.parse(SETTINGS, env: TOKENS)
    message = MailScore::Message.new("Subject: FIVE\n#{"X: y\n" * 1001}\nbody")
    verdict = MailScore::Scanner.new(config, rules: RULES, stats: @stats, database: @database).check(message, MailScore::Envelope.read({}, message))

    assert_equal %w[ FIVE TOO_MANY_HEADERS ], verdict.hits.map(&:name)
    assert_equal 6.0, verdict.score
  end

  def test_a_rule_reads_the_time_left_in_the_budget
    remaining = check("", rules: [ PatientRule ]).hits.first.detail

    assert_operator remaining, :<=, 8
    assert_operator remaining, :>, 7
  end

  def test_a_slow_last_rule_still_completes_the_scan
    verdict = check("FIVE", rules: [ RULES[0], SlowRule ], scan_budget: 0.05)

    assert verdict.complete
    assert_equal 0, @stats.to_h["budget_overruns"]
  end

  def test_a_timeout_can_soft_reject
    verdict = check("FIVE", rules: [ RULES[0], SlowRule, RULES[1] ], scan_budget: 0.05, soft_reject_on_timeout: true)

    assert_equal "soft_reject", verdict.action
    assert_equal "add_header", check("FIVE TWO", soft_reject_on_timeout: true).action
  end

  def test_a_timeout_never_turns_a_reject_into_a_soft_reject
    verdict = check("FIVE TEN", rules: [ RULES[0], RULES[2], SlowRule, RULES[1] ], scan_budget: 0.05, soft_reject_on_timeout: true)

    refute verdict.complete
    assert_equal "reject", verdict.action
  end

  def test_a_rule_that_raises_counts_as_not_fired
    verdict = check("FIVE TWO", rules: [ RULES[0], FailingRule, RULES[1] ])

    assert_equal %w[ FIVE TWO ], verdict.hits.map(&:name)
    assert verdict.complete
    assert_match "ERROR -- : FAILING raised Regexp::TimeoutError queue_id=-", log
    assert_equal 1, @stats.to_h["rule_errors"]
  end

  def test_a_rule_that_raises_fires_its_error_symbol_when_it_has_one
    failing = Class.new(MailScore::Rules::Authentication) { def run(*) = raise(ArgumentError) }

    verdict = check("FIVE", rules: [ RULES[0], failing ])

    assert_equal [ [ "FIVE", 5.0 ], [ "AUTHENTICATION_ERROR", 2.0 ] ], verdict.hits.map { [ it.name, it.weight ] }
    assert_equal 1, @stats.to_h["rule_errors"]
  end

  def test_a_rule_can_answer_with_several_hits
    verdict = check("FIVE", rules: [ RULES[0], PairRule ])

    assert_equal %w[ FIVE LEFT RIGHT ], verdict.hits.map(&:name)
    assert_equal 8.0, verdict.score
  end

  def test_a_hit_past_its_groups_max_score_adds_what_is_left_and_later_ones_nothing
    verdict = check("FIVE TWO TEN MINUS", groups: { "hfilter" => { "max_score" => 6 } })

    assert_equal [ [ "FIVE", 5 ], [ "TWO", 1.0 ], [ "TEN", 0.0 ], [ "MINUS", -0.1 ] ], verdict.hits.map { [ it.name, it.weight ] }
    assert_equal 5.9, verdict.score
    assert_equal "no_action", verdict.action
  end

  def test_a_negative_total_stops_at_the_groups_min_score
    verdict = check("MINUS", groups: { "hfilter" => { "min_score" => -0.05 } })

    assert_equal [ -0.05 ], verdict.hits.map(&:weight)
    assert_equal(-0.05, verdict.score)
  end

  def test_header_rules_add_at_most_eight_by_default
    rules = [ self.class.rule("FIVE", 5, "headers"), self.class.rule("TEN", 10, "headers") ]

    assert_equal [ 5, 3.0 ], check("FIVE TEN", rules:).hits.map(&:weight)
  end

  def test_url_dns_lists_add_at_most_twelve_and_a_half_by_default
    rules = [ self.class.rule("FIVE", 5, "surbl"), self.class.rule("TEN", 10, "surbl"), RULES[1] ]

    assert_equal [ 5, 7.5, 2 ], check("FIVE TEN TWO", rules:).hits.map(&:weight)
    assert_equal [ 5, 10, 2 ], check("FIVE TEN TWO", rules:, groups: { "surbl" => { "max_score" => 0 } }).hits.map(&:weight)
  end

  def test_what_is_left_under_a_cap_is_rounded
    rules = [ self.class.rule("SOME", 5.1, "headers"), self.class.rule("MORE", 2, "headers") ]

    assert_equal [ 5.1, 0.9 ], check("SOME MORE", rules:, groups: { "headers" => { "max_score" => 6 } }).hits.map(&:weight)
  end

  def test_a_timeout_counts_toward_its_groups_cap
    verdict = check("FIVE", rules: [ RULES[0], SlowRule, RULES[1] ], scan_budget: 0.05, groups: { "scan" => { "max_score" => 1 } })

    assert_equal [ [ "FIVE", 5 ], [ "SCAN_TIMED_OUT", 1.0 ] ], verdict.hits.map { [ it.name, it.weight ] }
    assert_equal 6.0, verdict.score
  end

  def test_a_failed_scan_is_capped
    config = MailScore::Config.parse(SETTINGS.merge("groups" => { "scan" => { "max_score" => 1 } }), env: TOKENS)
    verdict = MailScore::Scanner.new(config, rules: RULES, stats: @stats).failed(MailScore::Message.new("Subject: x\n\nbody"))

    assert_equal [ 1.0 ], verdict.hits.map(&:weight)
    assert_equal 1.0, verdict.score
  end

  def test_a_score_replaces_a_symbols_weight_and_off_drops_it
    verdict = check("FIVE TWO", scores: { "FIVE" => 1, "TWO" => false })

    assert_equal [ [ "FIVE", 1.0 ] ], verdict.hits.map { [ it.name, it.weight ] }
    assert_equal 1.0, verdict.score
    assert_equal "no_action", verdict.action
    assert_equal "reject", check("TWO", scores: { "TWO" => 20 }).action
  end

  def test_a_score_scales_as_the_rule_scaled_the_default
    assert_equal [ 3.0, 2.0 ], check("FIVE", rules: [ HalfRule, PairRule ], scores: { "HALF" => 6, "LEFT" => 2, "RIGHT" => false }).hits.map(&:weight)
  end

  def test_a_score_weighs_the_scanners_own_symbols
    verdict = check("FIVE TWO", rules: [ RULES[0], SlowRule, RULES[1] ], scan_budget: 0.05, scores: { "SCAN_TIMED_OUT" => 0.5 })

    assert_equal [ [ "FIVE", 5.0 ], [ "SCAN_TIMED_OUT", 0.5 ] ], verdict.hits.map { [ it.name, it.weight ] }
    assert_equal 5.5, verdict.score
  end

  def test_a_score_weighs_a_reputation_hit
    reputation = Object.new
    def reputation.hits(*) = [ MailScore::Hit.new(name: "IP_REPUTATION_SPAM", weight: 1.5) ]

    assert_equal [ 3.0 ], check("", reputation:, scores: { "IP_REPUTATION_SPAM" => 6 }).hits.map(&:weight)
  end

  def test_a_score_weighs_a_failed_scan
    config = MailScore::Config.parse(SETTINGS.merge("scores" => { "SCAN_ERROR" => 1 }), env: TOKENS)
    verdict = MailScore::Scanner.new(config, rules: RULES, stats: @stats).failed(MailScore::Message.new("Subject: x\n\nbody"))

    assert_equal [ [ "SCAN_ERROR", 1.0 ] ], verdict.hits.map { [ it.name, it.weight ] }
  end

  def test_a_group_caps_the_weights_in_use
    rules = [ self.class.rule("FIVE", 5, "headers"), self.class.rule("TWO", 2, "headers") ]
    verdict = check("FIVE TWO", rules:, scores: { "FIVE" => 6, "TWO" => 6 })

    assert_equal [ 6.0, 2.0 ], verdict.hits.map(&:weight)
    assert_equal 8.0, verdict.score
  end

  def test_a_score_for_an_unknown_symbol_fails
    error = assert_raises(MailScore::ConfigError) { check("FIVE", scores: { "FIVE" => 1, "SIX" => 6, "GREYLISTED" => 1 }) }

    assert_equal "unknown symbol in scores: SIX, GREYLISTED", error.message
  end

  def test_an_unknown_group_fails
    error = assert_raises(MailScore::ConfigError) { check("FIVE", groups: { "uribl" => { "max_score" => 12.5 } }) }

    assert_equal "unknown group: uribl", error.message
  end

  def test_every_rule_is_built_with_the_config_and_the_database
    assert_equal [ 8, 1 ], check("", rules: [ StoredRule ]).hits.first.detail
  end

  def test_scans_are_counted_per_action
    check("TWO")
    check("FIVE TEN")

    assert_equal 1, @stats.to_h["scans_no_action"]
    assert_equal 1, @stats.to_h["scans_reject"]
  end

  private
    def check(subject, actions: SETTINGS["actions"], greylister: nil, reputation: nil, rules: RULES, **settings)
      config = MailScore::Config.parse(SETTINGS.merge("actions" => actions, **settings.transform_keys(&:to_s)), env: TOKENS)
      message = MailScore::Message.new("Subject: #{subject}\n\nbody")
      scanner = MailScore::Scanner.new(config, rules:, stats: @stats, greylister:, reputation:, database: @database)
      scanner.check(message, MailScore::Envelope.read({}, message))
    end
end
