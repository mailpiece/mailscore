require "mailscore"
require "puma"
require "puma/configuration"
require "puma/launcher"

module MailScore
  # Puma in cluster mode. fastText and the rules hold the GVL, so scans run in
  # parallel only across processes.
  class Server
    TRAIN_CHECK = 3600
    # Room past message_size_cap for Puma's limit, so the app's own 413
    # answers a body just over the cap and Puma refuses the rest unread.
    BODY_HEADROOM = 65_536
    LIB = File.expand_path("..", __dir__)
    TRAIN = File.join(__dir__, "classifier", "train.rb")
    TRAINING = %w[ database database_busy_timeout log_level fasttext fasttext_model fasttext_min_samples fasttext_max_samples
      fasttext_sample_expiry fasttext_train_every ].freeze

    def initialize(config)
      @config = config
    end

    def run
      prepare
      launcher.run
    end

    # Runs once, before the workers fork.
    def prepare
      $stdout.sync = true
      MailScore.logger.level = @config.log_level
      warn_of_a_short_token
      Regexp.timeout = @config.regexp_timeout
      MailScore.nameservers = Nameservers.new(@config.nameservers).tap(&:resolve)
      prepare_database
      prepare_models
      Content::Url.homograph?("xn--80ak6aa92e.com") # Loads its tables for the workers to share
    end

    private
      # Logged once and never the token itself: a short token still serves.
      def warn_of_a_short_token
        if [ @config.read_token, @config.write_token ].any? { it.length < Config::TOKEN_MIN_LENGTH }
          MailScore.logger.warn "a token is shorter than #{Config::TOKEN_MIN_LENGTH} characters"
        end
      end

      # At boot: a database that can't be opened, such as one in a directory
      # that doesn't exist, stops the daemon.
      def prepare_database
        Database.new(@config.database, busy_timeout: @config.database_busy_timeout).tap(&:prepare).close
      rescue SQLite3::CantOpenException => error
        raise ConfigError, "database: #{error.message}: #{@config.database}"
      end

      # At boot, so the workers share them: a model that can't be loaded, or
      # one in a directory that doesn't exist, stops the daemon. The fastText
      # model is loaded once a training writes one.
      def prepare_models
        model("language_model", @config.language_model) { Bayes::Language.load(it) } if @config.language_model
        model("fasttext_model", @config.fasttext_model) { Classifier.model(it) } if @config.fasttext
      end

      def model(key, path)
        raise ConfigError, "#{key}: no such directory: #{File.dirname(path)}" unless File.directory?(File.dirname(path))
        yield path
      rescue ArgumentError
        raise ConfigError, "#{key}: cannot load #{path}"
      end

      def launcher
        Puma::Launcher.new(puma_configuration(App.new(@config)))
      end

      def puma_configuration(app)
        config = @config

        Puma::Configuration.new(config_files: [ "-" ]) do |puma|
          puma.environment "production"
          puma.port config.port, config.bind
          puma.http_content_length_limit config.message_size_cap + BODY_HEADROOM
          puma.workers config.workers
          puma.preload_app!
          puma.app app
          puma.before_worker_boot do |index|
            MailScore.nameservers.refresh_every(config.nameservers_refresh)
            if (lists = config.dnsbl + config.uribl).any?
              DnsList::Monitor.follow(app.database)
              DnsList::Monitor.start(lists, app.database) if index.zero?
            end
            if index.zero?
              expire_in_the_background(app.database)
              train_in_the_background(app.database) if config.fasttext
            end
          end
        end
      end

      # Each background loop logs an error by its class and goes on.
      def expire_in_the_background(database)
        bayes = Bayes.new(@config, database)

        Thread.new do
          loop do
            sleep @config.expire_every
            database.expire
            bayes.prune
          rescue StandardError => error
            MailScore.logger.error "expiry failed: #{error.class}"
          end
        end
      end

      # Checks every TRAIN_CHECK whether a training is due and runs it in a
      # child process: fastText holds the GVL while it trains, which would
      # stall this worker's scans.
      def train_in_the_background(database)
        trainer = Classifier::Trainer.new(@config, database)

        Thread.new do
          loop do
            train if trainer.due?
          rescue StandardError => error
            MailScore.logger.error "training failed: #{error.class}"
          ensure
            sleep TRAIN_CHECK
          end
        end
      end

      # A fresh Ruby, not a fork of this worker, so it shares none of its
      # threads, connections or memory.
      def train
        settings = TRAINING.to_h { [ it, @config.public_send(it) ] }
        tokens = { "MAILSCORE_READ_TOKEN" => @config.read_token, "MAILSCORE_WRITE_TOKEN" => @config.write_token }
        pid = Process.spawn(tokens, RbConfig.ruby, *("-rbundler/setup" if defined?(Bundler)), "-I", LIB, TRAIN, JSON.generate(settings))
        Process.wait(pid)
        MailScore.logger.error "training failed: exit #{$?.exitstatus}" unless $?.success?
      end
  end
end
