require "json"
require "rack/utils"

module MailScore
  # The HTTP API as a Rack app. See docs/api.md.
  class App
    ROUTES = {
      [ "POST", "/check" ] => :check,
      [ "GET", "/health" ] => :health,
      [ "GET", "/stats" ] => :stats,
      [ "GET", "/symbols" ] => :symbols,
      [ "POST", "/fuzzy/add" ] => :fuzzy_add,
      [ "POST", "/fuzzy/delete" ] => :fuzzy_delete,
      [ "POST", "/fuzzy/check" ] => :fuzzy_check,
      [ "POST", "/learn/spam" ] => :learn_spam,
      [ "POST", "/learn/ham" ] => :learn_ham
    }.freeze
    WRITES = %i[ learn_spam learn_ham fuzzy_add fuzzy_delete ].freeze

    attr_reader :database

    def initialize(config, database: Database.new(config.database, busy_timeout: config.database_busy_timeout), rules: Rules::ALL,
      greylister: Greylister.new(config, database), reputation: Reputation.new(config, database))
      @config = config
      @database = database
      @stats = Stats.new(database)
      @scanner = Scanner.new(config, rules:, stats: @stats, greylister:, reputation:, database:)
      @fuzzy = Fuzzy.new(config, database)
      @bayes = Bayes.new(config, database)
      @trap = Trap.new(config, database)
      @reputation = reputation
      @catalogue = @scanner.catalogue
      @descriptions = @catalogue.to_h { [ it[:name], it[:description] ] }
    end

    def call(env)
      method, path = env["REQUEST_METHOD"], env["PATH_INFO"]
      return [ 200, { "content-type" => "text/plain" }, [ "pong" ] ] if method == "GET" && path == "/ping"

      route = ROUTES.fetch([ method, path ], :not_found)
      token = bearer(env["HTTP_AUTHORIZATION"])

      if !readable?(token) || (WRITES.include?(route) && !writable?(token))
        @stats.count_in_memory("unauthorized")
        error(401, "unauthorized", "www-authenticate" => "Bearer")
      elsif env["CONTENT_LENGTH"].to_i > @config.message_size_cap
        @stats.increment("too_large")
        error(413, "too_large")
      else
        @stats.flush
        send(route, env)
      end
    rescue SQLite3::Exception
      error(503, "unavailable")
    end

    private
      def check(env)
        started = Envelope.now
        read_message(env) do |message|
          envelope = Envelope.read(env, message, local_networks: @config.local_networks)
          verdict, body = scan(message, envelope)
          after_verdict(message, envelope, verdict)
          elapsed = Envelope.now - started
          log "scan", env, action: verdict.action, score: verdict.score, complete: verdict.complete, ms: (elapsed * 1000).round
          [ 200, { "content-type" => "application/json" }, [ body ] ]
        end
      end

      # The verdict and its JSON. A scan that raises, short of the database,
      # answers the scanner's failed verdict instead, logged by the error's
      # class alone, as the message may be in its text.
      def scan(message, envelope)
        verdict = @scanner.check(message, envelope)
        [ verdict, JSON.generate(verdict.as_json(@descriptions)) ]
      rescue SQLite3::Exception
        raise
      rescue StandardError => error
        @stats.increment("scan_errors")
        MailScore.logger.error "scan raised #{error.class} queue_id=#{MailScore.log_field(envelope.queue_id)}"
        verdict = @scanner.failed(message)
        [ verdict, JSON.generate(verdict.as_json(@descriptions)) ]
      end

      # What waits for the verdict, so a message never scores itself. None of
      # it costs the caller its verdict. A trap learns first, so autolearn
      # finds a trapped message already learned.
      def after_verdict(message, envelope, verdict)
        spring_trap(message, envelope)
        record_reputation(message, envelope, verdict)
        autolearn(message, envelope, verdict)
      end

      def spring_trap(message, envelope)
        @trap.spring(message, envelope)
      rescue SQLite3::Exception => error
        MailScore.logger.error "trap failed: #{error.message}"
      end

      def record_reputation(message, envelope, verdict)
        @reputation.record(message, envelope, verdict)
      rescue SQLite3::Exception => error
        MailScore.logger.error "reputation failed: #{error.message}"
      end

      def autolearn(message, envelope, verdict)
        @bayes.autolearn(message, envelope, verdict)&.then { @stats.increment("autolearns_#{it}") }
      rescue SQLite3::Exception => error
        MailScore.logger.error "autolearn failed: #{error.message}"
      end

      def learn_spam(env)
        learn(env, "spam")
      end

      def learn_ham(env)
        learn(env, "ham")
      end

      def learn(env, klass)
        read_message(env) do |message|
          result = @bayes.learn(message, klass)
          log "learn", env, class: klass, result: { true => "learned", false => "already_learned" }.fetch(result, "too_short")

          case result
          when true
            @stats.increment("learns_#{klass}")
            json(200, learned: true)
          when false then error(208, "already_learned")
          else [ 204, {}, [] ]
          end
        end
      end

      def fuzzy_add(env)
        with_flag(env) { |flag| read_message(env) { json(200, hashes: add_fuzzy(env, it, flag)) } }
      end

      def fuzzy_delete(env)
        with_flag(env) { |flag| read_message(env) { json(200, hashes: delete_fuzzy(env, it, flag)) } }
      end

      def add_fuzzy(env, message, flag)
        @fuzzy.add(message, flag, count: weight(env)).tap { log "fuzzy_add", env, flag:, hashes: it }
      end

      def delete_fuzzy(env, message, flag)
        @fuzzy.delete(message, flag).tap { log "fuzzy_delete", env, flag:, hashes: it }
      end

      def fuzzy_check(env)
        read_message(env) { json(200, matches: @fuzzy.check(it).map(&:to_h)) }
      end

      def health(_env)
        @database.execute("SELECT 1")
        json(200, status: "ok", version: VERSION)
      end

      def stats(_env)
        json(200, { **@stats.to_h, "fasttext" => Classifier.new(@config, @database).stats })
      end

      def symbols(_env)
        json(200, @catalogue)
      end

      def not_found(_env)
        error(404, "not_found")
      end

      # Yields the body as a Message, or answers 413 or 400.
      def read_message(env)
        raw = env["rack.input"]&.read(@config.message_size_cap + 1).to_s
        if raw.bytesize > @config.message_size_cap
          @stats.increment("too_large")
          error(413, "too_large")
        elsif raw.empty?
          error(400, "malformed")
        else
          yield Message.new(raw)
        end
      end

      def with_flag(env)
        flag = Envelope.header(env, "FLAG").to_s
        @config.fuzzy_flags.key?(flag) ? yield(flag) : error(422, "unknown_flag")
      end

      # A positive whole number, else 1, as if the header were absent.
      def weight(env)
        Envelope.header(env, "WEIGHT").to_s.then { it.match?(/\A[1-9]\d{0,8}\z/) ? it.to_i : 1 }
      end

      # The write token does everything the read token does.
      def readable?(token)
        [ @config.read_token, @config.write_token ].any? { Rack::Utils.secure_compare(it, token) }
      end

      def writable?(token)
        Rack::Utils.secure_compare(@config.write_token, token)
      end

      def bearer(authorization)
        authorization.to_s[/\ABearer (\S+)\z/, 1].to_s
      end

      # One line per scan, learn or fuzzy change, keyed by the caller's
      # Queue-Id and client IP, each cleaned and capped. Never message
      # content, Subjects or addresses.
      def log(event, env, **fields)
        fields = { queue_id: Envelope.header(env, "QUEUE_ID"), **fields, ip: Envelope.header(env, "IP") }
        MailScore.logger.info { [ event, *fields.map { |key, value| "#{key}=#{MailScore.log_field(value)}" } ].join(" ") }
      end

      def json(status, body, headers = {})
        [ status, { "content-type" => "application/json", **headers }, [ JSON.generate(body) ] ]
      end

      def error(status, code, headers = {})
        json(status, { error: code }, headers)
      end
  end
end
