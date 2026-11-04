require "etc"
require "ipaddr"
require "maxmind/db"
require "yaml"
require "mailscore/error"
require "mailscore/list"
require "mailscore/dns_list"
require "mailscore/dns_list/parser"
require "mailscore/dns_list/candidates"

module MailScore
  # A setting mailscore cannot run on, raised at boot so a bad config stops
  # it there rather than in the middle of a scan.
  class ConfigError < Error; end

  # Settings from a YAML file, each with a default, and tokens from ENV.
  # Weights and scores are floats, however written. +thresholds+ lists the
  # actions lowest first, with nil for one switched off. +scores+ maps a
  # symbol to its weight, or nil for one switched off. +local_networks+ is
  # a list of IPAddr. +groups+ maps a symbol group to its Group, of floats
  # or nil. +fuzzy_flags+ maps a flag name to a FuzzyFlag.
  # +trap_addresses+ and +spf_reputation_exclusions+ are lowercase, and
  # +trap_fuzzy_flag+ is a fuzzy flag or nil. +dnsbl+ and +uribl+ are lists
  # of DnsList, empty by default. +nameservers+ lists addresses and host
  # names, or is nil for the system resolver. +language_model+ is a path, or
  # nil for none. +shorteners+, +trusted_redirectors+, +risky_extensions+ and
  # +archive_extensions+ are each a List, the bundled file by default.
  Config = Data.define(:database, :bind, :port, :workers, :message_size_cap, :scan_budget, :thresholds, :scores, :groups,
    :regexp_timeout, :database_busy_timeout, :expire_every, :subject_template, :soft_reject_on_timeout,
    :date_future_margin, :date_past_margin, :greylist_timeout, :greylist_expiry, :local_networks,
    :reputation_window, :reputation_min_count, :reputation_expiry, :spf_reputation_exclusions, :asn_database, :country_database,
    :fuzzy_flags, :fuzzy_expiry, :fuzzy_min_words, :fuzzy_threshold, :fuzzy_min_attachment_size,
    :bayes_min_learns, :bayes_max_tokens, :language_model, :autolearn, :autolearn_spam_score, :autolearn_ham_score,
    :trap_addresses, :trap_fuzzy_flag, :trap_learn_spam, :trap_allow_multiple_rcpts, :dnsbl, :uribl,
    :nameservers, :nameservers_refresh, :fasttext, :fasttext_model, :fasttext_min_samples, :fasttext_max_samples, :fasttext_sample_expiry, :fasttext_train_every,
    :shorteners, :trusted_redirectors, :risky_extensions, :archive_extensions, :log_level, :read_token, :write_token)

  class Config
    FuzzyFlag = Data.define(:symbol, :weight, :hits_limit)
    Group = Data.define(:max_score, :min_score)

    PATH = "/etc/mailscore.yml"
    LISTS = File.join(__dir__, "lists")
    # Lowest first, each a score or off.
    ACTIONS = { "greylist" => 4, "add_header" => 6, "rewrite_subject" => false, "soft_reject" => false, "reject" => 15 }.freeze
    # The groups capped by default, and their caps.
    GROUPS = { "headers" => { "max_score" => 8 }, "subject" => { "max_score" => 6 }, "phishing" => { "max_score" => 10 },
      "mime_types" => { "max_score" => 10 }, "url" => { "max_score" => 9 }, "surbl" => { "max_score" => 12.5 } }.freeze
    # Every setting but fasttext_model, which is fasttext.bin beside the
    # database. workers is one per CPU. nil is none: no language model, the
    # system resolver, or autolearn scores that follow the thresholds.
    DEFAULTS = {
      "database" => "/data/mailscore.sqlite3",
      "bind" => "0.0.0.0",
      "port" => 8080,
      "workers" => Etc.nprocessors,
      "message_size_cap" => 52_428_800,
      "scan_budget" => 8,
      "greylist_timeout" => 300,
      "greylist_expiry" => 86_400,
      "actions" => ACTIONS,
      "scores" => {}.freeze,
      "groups" => GROUPS,
      "regexp_timeout" => 0.5,
      "database_busy_timeout" => 5,
      "expire_every" => 60,
      "subject_template" => "*** SPAM *** %s",
      "soft_reject_on_timeout" => false,
      "date_future_margin" => 7200,
      "date_past_margin" => 86_400,
      "local_networks" => %w[ 127.0.0.0/8 ::1/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 169.254.0.0/16 fe80::/10 ].freeze,
      "bayes_min_learns" => 200,
      "bayes_max_tokens" => 1_000_000,
      "language_model" => nil,
      "autolearn" => false,
      "autolearn_spam_score" => nil,
      "autolearn_ham_score" => nil,
      "reputation_window" => 2_592_000,
      "reputation_min_count" => 10,
      "reputation_expiry" => 864_000,
      "spf_reputation_exclusions" => [].freeze,
      "asn_database" => false,
      "country_database" => false,
      "fuzzy_flags" => { "spam" => { "symbol" => "FUZZY_SPAM", "weight" => 12.0, "hits_limit" => 20 },
        "prob" => { "symbol" => "FUZZY_PROBABLE_SPAM", "weight" => 5.0, "hits_limit" => 10 },
        "ham" => { "symbol" => "FUZZY_HAM", "weight" => -2.1, "hits_limit" => 2 } }.freeze,
      "fuzzy_expiry" => 7_776_000,
      "fuzzy_min_words" => 64,
      "fuzzy_threshold" => 0.5,
      "fuzzy_min_attachment_size" => 1024,
      "trap_addresses" => [].freeze,
      "trap_fuzzy_flag" => false,
      "trap_learn_spam" => false,
      "trap_allow_multiple_rcpts" => false,
      "dnsbl" => [].freeze,
      "uribl" => [].freeze,
      "nameservers" => nil,
      "nameservers_refresh" => 300,
      "fasttext" => false,
      "fasttext_min_samples" => 200,
      "fasttext_max_samples" => 5000,
      "fasttext_sample_expiry" => 7_776_000,
      "fasttext_train_every" => 86_400,
      "shorteners" => File.join(LISTS, "shorteners.txt"),
      "trusted_redirectors" => File.join(LISTS, "trusted_redirectors.txt"),
      "risky_extensions" => File.join(LISTS, "risky_extensions.txt"),
      "archive_extensions" => File.join(LISTS, "archive_extensions.txt"),
      "log_level" => "info"
    }.freeze
    KEYS = [ *DEFAULTS.keys, "fasttext_model" ].freeze
    FUZZY_HITS_LIMIT = 20
    TOKEN_MIN_LENGTH = 32
    LOG_LEVELS = %w[ debug info warn error ].freeze
    EXPECTED = { String => "non-empty string", Integer => "positive integer", Numeric => "positive number" }.freeze

    # The highest action switched on whose threshold +score+ reaches, or nil.
    def action_for(score)
      thresholds.reverse_each.find { |_, threshold| threshold && score >= threshold }&.first
    end

    # "spam", "ham" or nil for a verdict's +score+. A score set is learned at
    # or past it; by default spam is learned above the reject threshold, or
    # its default with reject off, and ham below 0.
    def autolearn_class(score)
      if autolearn_spam_score ? score >= autolearn_spam_score : score > (thresholds["reject"] || ACTIONS["reject"]) then "spam"
      elsif autolearn_ham_score ? score <= autolearn_ham_score : score < 0 then "ham"
      end
    end

    class << self
      # Every default without a path. An empty file is no settings.
      def load(path, env: ENV)
        parse(path ? YAML.safe_load_file(path) || {} : {}, env: env)
      rescue SystemCallError => error
        raise ConfigError, error.message
      rescue Psych::SyntaxError => error
        raise ConfigError, "#{path}: #{error.problem} at line #{error.line} column #{error.column}"
      rescue Psych::Exception => error
        raise ConfigError, "#{path}: #{error.is_a?(Psych::BadAlias) ? "aliases are not allowed" : error.message}"
      end

      def parse(settings, env: ENV)
        raise ConfigError, "settings must be a mapping" unless settings.is_a?(Hash)
        check_keys(settings, KEYS, "setting")
        settings = DEFAULTS.merge(settings)

        autolearn = switch(settings["autolearn"], "autolearn")
        spam_score, ham_score = autolearn_scores(settings)

        fuzzy_flags = fuzzy_flags(settings["fuzzy_flags"])
        min_samples, max_samples = fasttext_samples(settings)

        read_token, write_token = token(env, "MAILSCORE_READ_TOKEN"), token(env, "MAILSCORE_WRITE_TOKEN")
        raise ConfigError, "set MAILSCORE_READ_TOKEN, MAILSCORE_WRITE_TOKEN or both" unless read_token || write_token

        database = setting(settings["database"], "database", String)

        new \
          database:,
          bind: address(settings["bind"], "bind"),
          port: setting(settings["port"], "port", Integer),
          workers: setting(settings["workers"], "workers", Integer),
          message_size_cap: setting(settings["message_size_cap"], "message_size_cap", Integer),
          scan_budget: setting(settings["scan_budget"], "scan_budget", Numeric),
          thresholds: thresholds(settings["actions"]),
          scores: scores(settings["scores"]),
          groups: groups(settings["groups"]),
          regexp_timeout: setting(settings["regexp_timeout"], "regexp_timeout", Numeric),
          database_busy_timeout: setting(settings["database_busy_timeout"], "database_busy_timeout", Numeric),
          expire_every: setting(settings["expire_every"], "expire_every", Numeric),
          subject_template: setting(settings["subject_template"], "subject_template", String),
          soft_reject_on_timeout: switch(settings["soft_reject_on_timeout"], "soft_reject_on_timeout"),
          date_future_margin: setting(settings["date_future_margin"], "date_future_margin", Numeric),
          date_past_margin: setting(settings["date_past_margin"], "date_past_margin", Numeric),
          greylist_timeout: setting(settings["greylist_timeout"], "greylist_timeout", Numeric),
          greylist_expiry: setting(settings["greylist_expiry"], "greylist_expiry", Numeric),
          local_networks: networks(settings["local_networks"], "local_networks"),
          reputation_window: setting(settings["reputation_window"], "reputation_window", Numeric),
          reputation_min_count: setting(settings["reputation_min_count"], "reputation_min_count", Numeric),
          reputation_expiry: setting(settings["reputation_expiry"], "reputation_expiry", Numeric),
          spf_reputation_exclusions: keys(settings["spf_reputation_exclusions"], "spf_reputation_exclusions"),
          asn_database: database_or_off(settings["asn_database"], "asn_database"),
          country_database: database_or_off(settings["country_database"], "country_database"),
          fuzzy_flags:,
          fuzzy_expiry: setting(settings["fuzzy_expiry"], "fuzzy_expiry", Numeric),
          fuzzy_min_words: setting(settings["fuzzy_min_words"], "fuzzy_min_words", Integer),
          fuzzy_threshold: fuzzy_threshold(settings["fuzzy_threshold"]),
          fuzzy_min_attachment_size: setting(settings["fuzzy_min_attachment_size"], "fuzzy_min_attachment_size", Integer),
          bayes_min_learns: setting(settings["bayes_min_learns"], "bayes_min_learns", Integer),
          bayes_max_tokens: setting(settings["bayes_max_tokens"], "bayes_max_tokens", Integer),
          language_model: settings["language_model"]&.then { setting(it, "language_model", String) },
          autolearn:,
          autolearn_spam_score: spam_score,
          autolearn_ham_score: ham_score,
          trap_addresses: addresses(settings["trap_addresses"], "trap_addresses"),
          trap_fuzzy_flag: flag_or_off(settings["trap_fuzzy_flag"], fuzzy_flags, "trap_fuzzy_flag"),
          trap_learn_spam: switch(settings["trap_learn_spam"], "trap_learn_spam"),
          trap_allow_multiple_rcpts: switch(settings["trap_allow_multiple_rcpts"], "trap_allow_multiple_rcpts"),
          dnsbl: DnsList::Parser.parse(settings["dnsbl"], "dnsbl", checks: %w[ from ]),
          uribl: DnsList::Parser.parse(settings["uribl"], "uribl", checks: %w[ urls ]),
          nameservers: settings["nameservers"]&.then { nameservers(it) },
          nameservers_refresh: setting(settings["nameservers_refresh"], "nameservers_refresh", Numeric),
          fasttext: switch(settings["fasttext"], "fasttext"),
          fasttext_model: setting(settings.fetch("fasttext_model") { File.join(File.dirname(database), "fasttext.bin") }, "fasttext_model", String),
          fasttext_min_samples: min_samples,
          fasttext_max_samples: max_samples,
          fasttext_sample_expiry: setting(settings["fasttext_sample_expiry"], "fasttext_sample_expiry", Numeric),
          fasttext_train_every: setting(settings["fasttext_train_every"], "fasttext_train_every", Numeric),
          shorteners: list(settings["shorteners"], "shorteners"),
          trusted_redirectors: list(settings["trusted_redirectors"], "trusted_redirectors"),
          risky_extensions: list(settings["risky_extensions"], "risky_extensions"),
          archive_extensions: list(settings["archive_extensions"], "archive_extensions"),
          log_level: log_level(settings["log_level"]),
          read_token: read_token || write_token,
          write_token: write_token || read_token
      end

      private
        def check_keys(hash, known, kind)
          if (unknown = hash.keys - known).any?
            raise ConfigError, "unknown #{kind}: #{unknown.join(", ")}"
          end
        end

        def token(env, name)
          env[name] unless env[name].to_s.empty?
        end

        def setting(value, key, type)
          valid = value.is_a?(type) && (type == String ? !value.empty? : value.positive?)
          raise ConfigError, "#{key} must be a #{EXPECTED.fetch(type)}" unless valid
          value
        end

        def switch(value, key)
          raise ConfigError, "#{key} must be on or off" unless value == true || value == false
          value
        end

        # Opened once at boot to check it, then closed: workers open their own.
        def database_or_off(value, key)
          raise ConfigError, "#{key} must be a MaxMind DB file or off" unless value == false || value.is_a?(String)
          MaxMind::DB.new(value).close if value
          value || nil
        rescue SystemCallError, MaxMind::DB::InvalidDatabaseError
          raise ConfigError, "#{key} must be a MaxMind DB file or off"
        end

        def list(value, key)
          raise ConfigError, "#{key} must be a readable file" unless value.is_a?(String)
          List.new(value)
        rescue SystemCallError, ArgumentError
          raise ConfigError, "#{key} must be a readable file"
        end

        def log_level(value)
          raise ConfigError, "log_level must be one of #{LOG_LEVELS.join(", ")}" unless LOG_LEVELS.include?(value)
          value
        end

        def fuzzy_threshold(value)
          raise ConfigError, "fuzzy_threshold must be a number from 0.5 to 1" unless value.is_a?(Numeric) && value >= 0.5 && value <= 1
          value
        end

        def fuzzy_flags(flags)
          raise ConfigError, "fuzzy_flags must be a mapping" unless flags.is_a?(Hash) && flags.any?

          flags.to_h do |flag, settings|
            hits_limit = settings.fetch("hits_limit", FUZZY_HITS_LIMIT) if settings.is_a?(Hash)
            valid = flag.is_a?(String) && settings.is_a?(Hash) && (settings.keys - %w[ hits_limit ]).sort == %w[ symbol weight ] &&
              settings["symbol"].to_s.match?(/\A[A-Z][A-Z0-9_]*\z/) && settings["weight"].is_a?(Numeric) &&
              hits_limit.is_a?(Numeric) && hits_limit.positive?
            raise ConfigError, "fuzzy_flags.#{flag} must have a symbol, a weight and an optional positive hits_limit" unless valid
            [ flag, FuzzyFlag.new(symbol: settings["symbol"], weight: settings["weight"].to_f, hits_limit:) ]
          end
        end

        # Spam above ham when both are set.
        def autolearn_scores(settings)
          scores = %w[ autolearn_spam_score autolearn_ham_score ].map do |key|
            raise ConfigError, "#{key} must be a number" unless settings[key].nil? || settings[key].is_a?(Numeric)
            settings[key]
          end

          raise ConfigError, "autolearn_spam_score must be above autolearn_ham_score" if scores.all? && scores.first <= scores.last
          scores
        end

        def fasttext_samples(settings)
          min = setting(settings["fasttext_min_samples"], "fasttext_min_samples", Integer)
          max = setting(settings["fasttext_max_samples"], "fasttext_max_samples", Integer)
          raise ConfigError, "fasttext_max_samples must be at least fasttext_min_samples" if max < min
          [ min, max ]
        end

        def addresses(value, key)
          raise ConfigError, "#{key} must be a list of addresses" unless value.is_a?(Array) && value.all? { it.is_a?(String) && it.include?("@") }
          value.map(&:downcase)
        end

        def nameservers(value)
          valid = value.is_a?(Array) && value.any? && value.all? { it.is_a?(String) && !it.empty? }
          raise ConfigError, "nameservers must be a list of addresses or host names" unless valid
          value
        end

        def flag_or_off(value, flags, key)
          raise ConfigError, "#{key} must be a fuzzy flag or off" unless value == false || flags.key?(value)
          value || nil
        end

        def keys(value, key)
          raise ConfigError, "#{key} must be a list of keys" unless value.is_a?(Array) && value.all?(String)
          value.map(&:downcase)
        end

        def address(value, key)
          raise ConfigError, "#{key} must be an IP address" unless value.is_a?(String) && IPAddr.new(value).prefix == (value.include?(":") ? 128 : 32)
          value
        rescue IPAddr::Error
          raise ConfigError, "#{key} must be an IP address"
        end

        def networks(value, key)
          raise ConfigError, "#{key} must be a list of networks" unless value.is_a?(Array) && value.all?(String)
          value.map { IPAddr.new(it) }
        rescue IPAddr::Error
          raise ConfigError, "#{key} must be a list of networks"
        end

        # A partial mapping keeps the defaults for the actions it leaves out.
        def thresholds(actions)
          raise ConfigError, "actions must be a mapping" unless actions.is_a?(Hash)
          check_keys(actions, ACTIONS.keys, "action")

          thresholds = ACTIONS.merge(actions).to_h do |action, value|
            raise ConfigError, "actions.#{action} must be a number or off" unless value == false || value.is_a?(Numeric)
            [ action, (value.to_f if value) ]
          end

          on = thresholds.values.compact
          raise ConfigError, "action thresholds must rise from greylist to reject" unless on == on.sort
          thresholds
        end

        # The scanner checks each name against the symbols it knows.
        def scores(scores)
          raise ConfigError, "scores must be a mapping" unless scores.is_a?(Hash)

          scores.to_h do |name, value|
            raise ConfigError, "scores.#{name} must be a number or off" unless value == false || value.is_a?(Numeric)
            [ name, (value.to_f if value) ]
          end
        end

        # A group left out keeps its default, as does a score a group leaves
        # out. max_score is 0 or more and min_score 0 or less.
        # The scanner checks each name against the groups there are.
        def groups(groups)
          raise ConfigError, "groups must be a mapping" unless groups.is_a?(Hash)

          merged = GROUPS.merge(groups) { |_, default, own| own.is_a?(Hash) ? default.merge(own) : own }
          merged.to_h { |name, scores| [ name, group(name, scores) ] }
        end

        def group(name, scores)
          valid = scores.is_a?(Hash) && (scores.keys - %w[ max_score min_score ]).empty? && scores.values.all?(Numeric) &&
            scores.fetch("max_score", 0) >= 0 && scores.fetch("min_score", 0) <= 0
          raise ConfigError, "groups.#{name} must have a max_score of 0 or more, a min_score of 0 or less, or both" unless valid
          Group.new(max_score: scores["max_score"]&.to_f, min_score: scores["min_score"]&.to_f)
        end
    end
  end
end
