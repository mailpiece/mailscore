module MailScore
  class DnsList
    # Probes a list for a name a working list does not list, as Rspamd does.
    # Worker 0 probes and records offline zones; every worker reads them.
    class Monitor
      INTERVAL = 60.0
      MAX_ERRORS = 2
      FIRST_MULT = 0.1
      MAX_MULT = 32.0
      OFFLINE_MULT = 8.0
      READ_EVERY = 5
      LABEL = [ *"a".."z", *"A".."Z", *"0".."9" ].freeze

      # One probe thread per zone, in worker 0.
      def self.start(lists, database)
        lists.reject(&:disable_monitoring).uniq(&:zone).map { new(it, database).start }
      end

      # Every worker rereads the offline zones every READ_EVERY seconds, and
      # keeps the last it read when the database fails.
      def self.follow(database)
        Thread.new do
          loop do
            read(database)
          rescue StandardError => error
            MailScore.logger.error "DNS list state read failed: #{error.class}"
          ensure
            sleep READ_EVERY
          end
        end
      end

      def self.read(database)
        MailScore.offline_dns_lists = database.execute("SELECT zone FROM offline_dns_lists").flatten.to_set
      end

      def initialize(list, database, dns: nil)
        @list = list
        @database = database
        @dns = dns
        @offline = false
        @recorded = nil
        @errors = 0
        @mult = 1.0
      end

      def offline?
        @offline
      end

      def start
        Thread.new do
          sleep jittered(FIRST_MULT)
          loop do
            probe
          rescue StandardError => error
            MailScore.logger.error "#{@list.shown_zone} probe failed: #{error.class}"
          ensure
            sleep jittered(@mult)
          end
        end
      end

      def probe
        case answer = DnsList.answer(name, resolver)
        when nil then passed
        when Array then failed("listed as #{answer.join(", ")}")
        else failed(FAILURES.fetch(answer.class, "error"))
        end
        record
      end

      private
        def resolver
          @dns || MailResolver::Resolver.new(nameservers: MailScore.nameservers.addresses)
        end

        # On the first probe, so a restarted worker 0 drops the row it left,
        # then on each change, retried while the write fails.
        def record
          return if @recorded == @offline

          sql = @offline ? "INSERT OR IGNORE INTO offline_dns_lists (zone) VALUES (?)" : "DELETE FROM offline_dns_lists WHERE zone = ?"
          @database.execute(sql, @list.zone)
          @recorded = @offline
        end

        def name
          label = Array.new(rand(8..31)) { LABEL.sample }.join if @list.random_monitored
          "#{label || @list.monitored_address}.#{@list.zone}"
        end

        def passed
          @errors = 0
          if @offline
            @offline = false
            @mult = 1.0
            MailScore.logger.info "#{@list.shown_zone} back online"
          else
            @mult = [ @mult * 2, MAX_MULT ].min
          end
        end

        def failed(error)
          if @offline
            @mult = [ @mult * 2, OFFLINE_MULT ].min
          elsif @errors < MAX_ERRORS
            @errors += 1
            @mult = @mult < 1 ? 1.0 : @mult / 2
          else
            @offline = true
            @mult = 2.0
            MailScore.logger.warn "#{@list.shown_zone} offline, not asked until its probe is not listed: #{error}"
          end
        end

        def jittered(mult)
          INTERVAL * mult * (1 + rand)
        end
    end
  end
end
