require "test_helper"
require_relative "support/mmdb"

class MailScore::ConfigTest < MailScore::TestCase
  EXAMPLE = File.expand_path("../docs/mailscore.example.yml", __dir__)
  # Shown in the example with a value of their own: worked out at start, or
  # empty or none by default.
  SHOWN_AS_EXAMPLES = %w[ workers local_networks language_model autolearn_spam_score autolearn_ham_score
    trap_addresses dnsbl uribl nameservers scores shorteners trusted_redirectors risky_extensions
    archive_extensions ].freeze
  # Shown with a file of the operator's own, which is not here.
  LISTS = %w[ shorteners trusted_redirectors risky_extensions archive_extensions ].freeze

  def test_the_example_config_parses_and_lists_every_setting
    assert_equal parse({}), MailScore::Config.load(EXAMPLE, env: TOKENS)

    MailScore::Config.parse(example_settings.except(*LISTS), env: TOKENS)
    assert_equal MailScore::Config::KEYS.sort, example_settings.keys.sort
  end

  def test_the_example_config_shows_each_default
    defaults = MailScore::Config::DEFAULTS.merge("fasttext_model" => parse({}).fasttext_model)

    (MailScore::Config::KEYS - SHOWN_AS_EXAMPLES).each do |key|
      assert_equal defaults.fetch(key), example_settings.fetch(key), key
    end
  end

  def test_every_setting_has_a_default
    config = parse({})

    assert_equal [ "/data/mailscore.sqlite3", 52_428_800, 8, 300, 86_400 ],
      config.to_h.values_at(:database, :message_size_cap, :scan_budget, :greylist_timeout, :greylist_expiry)
    assert_equal({ "greylist" => 4.0, "add_header" => 6.0, "rewrite_subject" => nil, "soft_reject" => nil, "reject" => 15.0 }, config.thresholds)
  end

  def test_an_empty_file_or_no_file_takes_every_default
    path = File.join(Dir.mktmpdir, "mailscore.yml").tap { File.write(it, "") }

    assert_equal parse({}), MailScore::Config.load(path, env: TOKENS)
    assert_equal parse({}), MailScore::Config.load(nil, env: TOKENS)
  end

  def test_a_partial_actions_mapping_keeps_the_other_defaults
    config = parse({ "actions" => { "add_header" => 5, "rewrite_subject" => 8 } })

    assert_equal({ "greylist" => 4.0, "add_header" => 5.0, "rewrite_subject" => 8.0, "soft_reject" => nil, "reject" => 15.0 }, config.thresholds)
    assert_nil parse({ "actions" => { "greylist" => false } }).thresholds["greylist"]
  end

  def test_a_full_config_loads_from_yaml_over_the_defaults
    path = File.join(Dir.mktmpdir, "mailscore.yml")
    File.write(path, <<~YAML)
      database: /data/mailscore.sqlite3
      port: 9000
      workers: 2
      message_size_cap: 26214400
      scan_budget: 5
      greylist_timeout: 600
      greylist_expiry: 3600
      actions:
        greylist: off
        add_header: 7
        rewrite_subject: 9
        soft_reject: off
        reject: 20
    YAML

    config = MailScore::Config.load(path, env: TOKENS)

    assert_equal "/data/mailscore.sqlite3", config.database
    assert_equal 9000, config.port
    assert_equal 2, config.workers
    assert_equal 26_214_400, config.message_size_cap
    assert_equal 5, config.scan_budget
    assert_equal 600, config.greylist_timeout
    assert_equal 3600, config.greylist_expiry
    assert_equal({ "greylist" => nil, "add_header" => 7, "rewrite_subject" => 9, "soft_reject" => nil, "reject" => 20 }, config.thresholds)
  end

  def test_port_and_workers_are_optional
    config = parse(SETTINGS)

    assert_equal 8080, config.port
    assert_predicate config.workers, :positive?
  end

  def test_timeouts_and_the_expiry_interval_have_defaults
    config = parse(SETTINGS)

    assert_equal 0.5, config.regexp_timeout
    assert_equal 5, config.database_busy_timeout
    assert_equal 60, config.expire_every
  end

  def test_the_date_margins_have_defaults_and_can_be_set
    assert_equal [ 7200, 86_400 ], parse(SETTINGS).then { [ it.date_future_margin, it.date_past_margin ] }
    assert_equal [ 600, 3600 ], parse(SETTINGS.merge("date_future_margin" => 600, "date_past_margin" => 3600)).then { [ it.date_future_margin, it.date_past_margin ] }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("date_past_margin" => 0)) }
  end

  def test_the_reputation_settings_have_defaults_and_can_be_set
    reputation = ->(config) { [ config.reputation_window, config.reputation_min_count, config.reputation_expiry ] }

    assert_equal [ 2_592_000, 10, 864_000 ], reputation[parse(SETTINGS)]
    assert_equal [ 3600, 2.5, 86_400 ], reputation[parse(SETTINGS.merge("reputation_window" => 3600, "reputation_min_count" => 2.5, "reputation_expiry" => 86_400))]
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("reputation_min_count" => 0)) }
  end

  def test_the_asn_and_country_databases_are_off_by_default_and_must_be_maxmind_db_files
    dir = Dir.mktmpdir
    path = File.join(dir, "GeoLite2-ASN.mmdb").tap { MMDB.write(it, "GeoLite2-ASN", "203.0.113.0/24" => { "autonomous_system_number" => 64500 }) }
    empty = File.join(dir, "empty.mmdb").tap { File.write(it, "") }

    assert_equal [ nil, nil ], parse(SETTINGS).then { [ it.asn_database, it.country_database ] }
    assert_equal [ path, nil ], parse(SETTINGS.merge("asn_database" => path, "country_database" => false)).then { [ it.asn_database, it.country_database ] }
    [ "/nonexistent/GeoLite2-Country.mmdb", dir, empty, 3 ].each do |value|
      assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("country_database" => value)) }
    end
  end

  def test_the_lists_are_bundled_and_a_file_replaces_one
    path = File.join(Dir.mktmpdir, "shorteners.txt").tap { File.write(it, "# Ours\n\nShort.Example # a comment\n  go.example\n") }

    assert_includes parse(SETTINGS).shorteners, "bit.ly"
    assert_includes parse(SETTINGS).trusted_redirectors, "urldefense.com"
    assert_equal [ 118, 11 ], parse(SETTINGS).then { [ it.risky_extensions.size, it.archive_extensions.size ] }
    assert_equal [ "short.example", "go.example" ], parse(SETTINGS.merge("shorteners" => path)).shorteners.to_a
  end

  def test_a_list_must_be_a_readable_file
    [ "/nonexistent/shorteners.txt", Dir.mktmpdir, 3 ].each do |value|
      assert_equal "shorteners must be a readable file", assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("shorteners" => value)) }.message
    end
  end

  def test_nameservers_are_off_by_default_and_take_addresses_or_host_names
    assert_equal [ nil, 300 ], parse(SETTINGS).then { [ it.nameservers, it.nameservers_refresh ] }
    assert_equal [ [ "192.0.2.53", "unbound" ], 60 ],
      parse(SETTINGS.merge("nameservers" => [ "192.0.2.53", "unbound" ], "nameservers_refresh" => 60)).then { [ it.nameservers, it.nameservers_refresh ] }
    [ [], "unbound", [ "" ], [ 53 ] ].each do |value|
      assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("nameservers" => value)) }
    end
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("nameservers_refresh" => 0)) }
  end

  def test_timeouts_and_the_expiry_interval_can_be_set
    config = parse(SETTINGS.merge("regexp_timeout" => 1, "database_busy_timeout" => 2.5, "expire_every" => 30))

    assert_equal 1, config.regexp_timeout
    assert_equal 2.5, config.database_busy_timeout
    assert_equal 30, config.expire_every
  end

  def test_the_subject_template_has_a_default
    assert_equal "*** SPAM *** %s", parse(SETTINGS).subject_template
    assert_equal "[spam] %s", parse(SETTINGS.merge("subject_template" => "[spam] %s")).subject_template
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("subject_template" => "")) }
  end

  def test_the_log_level_is_info_by_default
    assert_equal "info", parse(SETTINGS).log_level
    assert_equal "warn", parse(SETTINGS.merge("log_level" => "warn")).log_level
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("log_level" => "verbose")) }
  end

  def test_a_timeout_soft_rejects_only_when_switched_on
    refute parse(SETTINGS).soft_reject_on_timeout
    assert parse(SETTINGS.merge("soft_reject_on_timeout" => true)).soft_reject_on_timeout
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("soft_reject_on_timeout" => "yes")) }
  end

  def test_bayes_answers_after_200_learns_of_each_class_by_default
    assert_equal 200, parse(SETTINGS).bayes_min_learns
    assert_equal 50, parse(SETTINGS.merge("bayes_min_learns" => 50)).bayes_min_learns
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("bayes_min_learns" => 0)) }
    assert_equal 1_000_000, parse(SETTINGS).bayes_max_tokens
  end

  def test_bayes_has_no_language_model_by_default
    assert_nil parse(SETTINGS).language_model
    assert_equal "/data/lid.176.ftz", parse(SETTINGS.merge("language_model" => "/data/lid.176.ftz")).language_model
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("language_model" => "")) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("language_model" => true)) }
  end

  def test_fasttext_is_off_by_default_and_keeps_5000_samples_a_class_for_90_days
    config = parse(SETTINGS)

    refute config.fasttext
    assert_equal [ 5000, 7_776_000 ], [ config.fasttext_max_samples, config.fasttext_sample_expiry ]
    assert parse(SETTINGS.merge("fasttext" => true)).fasttext
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("fasttext_max_samples" => 0)) }
  end

  def test_fasttext_trains_daily_once_each_class_has_200_samples_into_a_model_beside_the_database
    config = parse(SETTINGS)

    assert_equal [ 200, 86_400, "/data/fasttext.bin" ], [ config.fasttext_min_samples, config.fasttext_train_every, config.fasttext_model ]
    assert_equal "/models/spam.bin", parse(SETTINGS.merge("fasttext_model" => "/models/spam.bin")).fasttext_model
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("fasttext_min_samples" => 6000)) }
  end

  def test_autolearn_is_off_by_default
    config = parse(SETTINGS)

    refute config.autolearn
    assert_nil config.autolearn_spam_score
    assert_nil config.autolearn_ham_score
  end

  def test_autolearn_on_alone_learns_spam_above_reject_and_ham_below_zero
    config = parse(SETTINGS.merge("autolearn" => true))

    assert config.autolearn
    assert_equal [ nil, "spam", nil, nil, "ham" ], [ 15, 15.5, 5, 0, -0.5 ].map { config.autolearn_class(it) }
  end

  def test_autolearn_spam_default_follows_reject
    assert_equal [ nil, "spam" ], [ 10, 10.5 ].map { parse(SETTINGS.merge("actions" => { "reject" => 10 })).autolearn_class(it) }
    assert_equal [ nil, "spam" ], [ 15, 15.5 ].map { parse(SETTINGS.merge("actions" => { "reject" => false })).autolearn_class(it) }
  end

  def test_autolearn_scores_set_override_the_defaults_and_are_reached
    config = parse(SETTINGS.merge("autolearn" => true, "autolearn_spam_score" => 12, "autolearn_ham_score" => -2))

    assert_equal [ 12, -2 ], [ config.autolearn_spam_score, config.autolearn_ham_score ]
    assert_equal [ "spam", nil, nil, "ham" ], [ 12, 11.5, -1.5, -2 ].map { config.autolearn_class(it) }
    assert_equal [ "spam", nil, "ham" ], [ 12, 0, -0.5 ].map { parse(SETTINGS.merge("autolearn_spam_score" => 12)).autolearn_class(it) }
  end

  def test_autolearn_scores_must_be_numbers_with_spam_above_ham
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("autolearn_spam_score" => "high")) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("autolearn_spam_score" => 1, "autolearn_ham_score" => 1)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("autolearn" => "on")) }
  end

  def test_local_networks_default_to_loopback_private_and_link_local_ranges
    networks = parse(SETTINGS).local_networks

    %w[ 127.0.0.1 ::1 10.1.2.3 172.31.0.1 192.168.1.1 fd00::1 fc00::1 169.254.1.1 fe80::1 febf::1 ].each { |ip| assert networks.any? { it.include?(ip) }, ip }
    %w[ 203.0.113.9 172.32.0.1 2001:db8::1 169.255.0.1 fec0::1 ].each { |ip| refute networks.any? { it.include?(ip) }, ip }
  end

  def test_local_networks_can_be_set_or_emptied
    assert_equal [ IPAddr.new("198.51.100.0/24") ], parse(SETTINGS.merge("local_networks" => [ "198.51.100.0/24" ])).local_networks
    assert_empty parse(SETTINGS.merge("local_networks" => [])).local_networks
  end

  def test_local_networks_must_be_a_list_of_networks
    [ "10.0.0.0/8", [ "not a network" ], [ 10 ] ].each do |value|
      error = assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("local_networks" => value)) }
      assert_equal "local_networks must be a list of networks", error.message
    end
  end

  def test_an_unknown_action_fails
    error = assert_raises(MailScore::ConfigError) { parse(with_actions("discard" => 20)) }

    assert_equal "unknown action: discard", error.message
  end

  def test_actions_must_be_a_mapping
    assert_equal "actions must be a mapping", assert_raises(MailScore::ConfigError) { parse(with_actions(nil)) }.message
  end

  def test_scores_give_a_symbol_a_weight_or_switch_it_off
    assert_equal({}, parse({}).scores)
    assert_equal({ "DMARC_PASS" => -0.3, "SPF_FAIL" => 2.0, "SUBJECT_ALL_CAPS" => nil },
      parse(SETTINGS.merge("scores" => { "DMARC_PASS" => -0.3, "SPF_FAIL" => 2, "SUBJECT_ALL_CAPS" => false })).scores)
  end

  def test_a_score_must_be_a_number_or_off
    [ "2", true, nil ].each do |value|
      error = assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("scores" => { "SPF_FAIL" => value })) }
      assert_equal "scores.SPF_FAIL must be a number or off", error.message
    end
    assert_equal "scores must be a mapping", assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("scores" => [ "SPF_FAIL" ])) }.message
  end

  def test_an_unknown_setting_fails
    error = assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("scan_budjet" => 8)) }

    assert_equal "unknown setting: scan_budjet", error.message
  end

  def test_a_non_positive_number_fails
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("message_size_cap" => 0)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("scan_budget" => "8s")) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("workers" => 1.5)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("expire_every" => 0)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("greylist_timeout" => 0)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("greylist_expiry" => -1)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("database" => "")) }
  end

  def test_a_threshold_must_be_a_number_or_off
    error = assert_raises(MailScore::ConfigError) { parse(with_actions(SETTINGS["actions"].merge("greylist" => true))) }

    assert_equal "actions.greylist must be a number or off", error.message
  end

  def test_thresholds_that_switch_on_must_rise
    error = assert_raises(MailScore::ConfigError) { parse(with_actions(SETTINGS["actions"].merge("add_header" => 20))) }

    assert_equal "action thresholds must rise from greylist to reject", error.message
    assert_raises(MailScore::ConfigError) { parse(with_actions("reject" => 3)) }
  end

  def test_groups_have_default_caps
    caps = { "headers" => 8.0, "subject" => 6.0, "phishing" => 10.0, "mime_types" => 10.0, "url" => 9.0, "surbl" => 12.5 }

    assert_equal caps.transform_values { MailScore::Config::Group.new(max_score: it, min_score: nil) }, parse(SETTINGS).groups
  end

  def test_a_group_left_out_or_a_score_a_group_leaves_out_keeps_its_default
    groups = parse(SETTINGS.merge("groups" => { "headers" => { "max_score" => 0 }, "surbl" => { "min_score" => -2 }, "hfilter" => { "max_score" => 5 } })).groups

    assert_equal MailScore::Config::Group.new(max_score: 0.0, min_score: nil), groups["headers"]
    assert_equal MailScore::Config::Group.new(max_score: 12.5, min_score: -2.0), groups["surbl"]
    assert_equal MailScore::Config::Group.new(max_score: 5.0, min_score: nil), groups["hfilter"]
    assert_equal 9.0, groups["url"].max_score
  end

  def test_groups_are_checked
    assert_equal "groups must be a mapping", assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("groups" => [])) }.message

    [ { "max_score" => -1 }, { "min_score" => 1 }, { "max_score" => "8" }, { "max" => 8 }, nil ].each do |scores|
      error = assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("groups" => { "headers" => scores })) }
      assert_equal "groups.headers must have a max_score of 0 or more, a min_score of 0 or less, or both", error.message
    end
  end

  def test_fuzzy_settings_have_defaults
    config = parse(SETTINGS)

    assert_equal({ "spam" => MailScore::Config::FuzzyFlag.new(symbol: "FUZZY_SPAM", weight: 12, hits_limit: 20),
      "prob" => MailScore::Config::FuzzyFlag.new(symbol: "FUZZY_PROBABLE_SPAM", weight: 5, hits_limit: 10),
      "ham" => MailScore::Config::FuzzyFlag.new(symbol: "FUZZY_HAM", weight: -2.1, hits_limit: 2) }, config.fuzzy_flags)
    assert_equal [ 7_776_000, 64, 0.5, 1024 ], config.to_h.values_at(:fuzzy_expiry, :fuzzy_min_words, :fuzzy_threshold, :fuzzy_min_attachment_size)
  end

  def test_fuzzy_flags_can_be_set
    flags = { "phish" => { "symbol" => "FUZZY_PHISH", "weight" => 8.5 }, "bulk" => { "symbol" => "FUZZY_BULK", "weight" => 3, "hits_limit" => 50 } }
    config = parse(SETTINGS.merge("fuzzy_flags" => flags))

    assert_equal({ "phish" => MailScore::Config::FuzzyFlag.new(symbol: "FUZZY_PHISH", weight: 8.5, hits_limit: 20),
      "bulk" => MailScore::Config::FuzzyFlag.new(symbol: "FUZZY_BULK", weight: 3, hits_limit: 50) }, config.fuzzy_flags)
  end

  def test_fuzzy_flags_need_a_symbol_and_a_weight
    [ { "spam" => { "symbol" => "FUZZY_SPAM" } }, { "spam" => { "symbol" => "fuzzy", "weight" => 1 } }, { "spam" => "FUZZY_SPAM" },
      { "spam" => { "symbol" => "FUZZY_SPAM", "weight" => 1, "hits_limit" => 0 } },
      { "spam" => { "symbol" => "FUZZY_SPAM", "weight" => 1, "limit" => 5 } } ].each do |flags|
      error = assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("fuzzy_flags" => flags)) }
      assert_equal "fuzzy_flags.spam must have a symbol, a weight and an optional positive hits_limit", error.message
    end
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("fuzzy_flags" => {})) }
  end

  def test_traps_are_off_by_default
    config = parse(SETTINGS)

    assert_equal [ [], nil, false, false ], config.to_h.values_at(:trap_addresses, :trap_fuzzy_flag, :trap_learn_spam, :trap_allow_multiple_rcpts)
  end

  def test_traps_can_be_set
    config = parse(SETTINGS.merge("trap_addresses" => [ "Trap@Example.net" ], "trap_fuzzy_flag" => "spam", "trap_learn_spam" => true,
      "trap_allow_multiple_rcpts" => true))

    assert_equal [ [ "trap@example.net" ], "spam", true, true ],
      config.to_h.values_at(:trap_addresses, :trap_fuzzy_flag, :trap_learn_spam, :trap_allow_multiple_rcpts)
  end

  def test_trap_settings_are_checked
    assert_equal "trap_addresses must be a list of addresses", assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_addresses" => "trap@example.net")) }.message
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_addresses" => [ "trap" ])) }
    assert_equal "trap_fuzzy_flag must be a fuzzy flag or off", assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_fuzzy_flag" => "phish")) }.message
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_fuzzy_flag" => true)) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_learn_spam" => "yes")) }
    assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("trap_allow_multiple_rcpts" => "yes")) }
  end

  def test_the_fuzzy_threshold_is_from_a_half_to_one
    assert_equal 1, parse(SETTINGS.merge("fuzzy_threshold" => 1)).fuzzy_threshold
    assert_equal 0.5, parse(SETTINGS.merge("fuzzy_threshold" => 0.5)).fuzzy_threshold
    [ 0, 0.4, 1.5, "high" ].each do |value|
      assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("fuzzy_threshold" => value)) }
    end
  end

  def test_bind_is_an_ip_address_all_of_them_by_default
    assert_equal "0.0.0.0", parse(SETTINGS).bind
    assert_equal "::", parse(SETTINGS.merge("bind" => "::")).bind
    [ "localhost", "10.0.0.0/8", "", 1 ].each do |value|
      assert_raises(MailScore::ConfigError) { parse(SETTINGS.merge("bind" => value)) }
    end
  end

  def test_one_token_serves_both
    config = parse(SETTINGS, env: { "MAILSCORE_READ_TOKEN" => "only-token-000000000000000000000" })

    assert_equal "only-token-000000000000000000000", config.read_token
    assert_equal "only-token-000000000000000000000", config.write_token
  end

  def test_no_token_fails
    assert_raises(MailScore::ConfigError) { parse(SETTINGS, env: { "MAILSCORE_READ_TOKEN" => "" }) }
  end

  def test_bad_yaml_fails_in_one_line_naming_the_file
    { "port: [\n" => "did not find expected node content at line 2 column 1",
      "a: &x 1\nb: *x\n" => "aliases are not allowed",
      "port: 2024-01-01\n" => "Tried to load unspecified class: Date" }.each do |yaml, message|
      path = File.join(Dir.mktmpdir, "mailscore.yml").tap { File.write(it, yaml) }

      error = assert_raises(MailScore::ConfigError) { MailScore::Config.load(path, env: TOKENS) }
      assert_equal "#{path}: #{message}", error.message
    end
  end

  def test_a_missing_file_fails
    error = assert_raises(MailScore::ConfigError) { MailScore::Config.load("/nonexistent/mailscore.yml", env: TOKENS) }
    assert_kind_of MailScore::Error, error
  end

  private
    def example_settings
      YAML.safe_load(File.read(EXAMPLE).gsub(/^# (?=[a-z_]+:| )/, ""))
    end

    def parse(settings, env: TOKENS)
      MailScore::Config.parse(settings, env: env)
    end

    def with_actions(actions)
      SETTINGS.merge("actions" => actions)
    end
end
