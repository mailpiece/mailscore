module MailScore
  # What /check answers for one message. +action+ is a config action name or
  # "no_action". Each symbol carries its description from +descriptions+,
  # name to description, as /symbols lists them.
  Verdict = Data.define(:action, :score, :complete, :hits, :subject)

  class Verdict
    REPLIES = {
      "soft_reject" => { code: 451, enhanced: "4.7.1", text: "Try again later" },
      "reject" => { code: 554, enhanced: "5.7.1", text: "Spam message rejected" }
    }.freeze

    def as_json(descriptions = {})
      symbols = hits.map { { **it.to_h.except(:data), description: descriptions[it.name] }.compact }
      { action: action.tr("_", " "), score: score, complete: complete, symbols: }.tap do |answer|
        answer[:smtp_reply] = REPLIES[action] if REPLIES.key?(action)
        answer[:subject] = subject if action == "rewrite_subject"
      end
    end

    # Held back by the greylister until a retry, which gives the real outcome.
    def greylisted?
      hits.any? { it.name == Greylister::NAME && it.detail == "greylisted" }
    end
  end

  # One scan: every rule within the budget, then the highest action whose
  # threshold the score reaches, or the one a hit forces. The clock is read before each rule, and past
  # the budget the rest are skipped with SCAN_TIMED_OUT, its detail the
  # first rule skipped. A rule that raises counts as not fired, or fires its
  # +ERROR+ symbol when it has one. The caps the
  # message reached fire after the rules, and reputation scores after them;
  # App records it after the verdict. A scan that raises gets the +failed+
  # verdict instead: incomplete, with SCAN_ERROR. The +scores+ setting
  # weighs every hit but the greylister's, which holds a decision, not a
  # weight. Before the action, each symbol group's max_score and min_score
  # bound what its weighed hits add.
  #
  # Both weigh 3.0, about what one of the late rules, a DNS list, Bayes or
  # fastText, adds for spam, so a message cannot score low by slowing the
  # scan or failing it. Alone, short of the greylist threshold, they cost
  # mail nothing when a slow nameserver is to blame; with a little else
  # against the message, they greylist it, and the retry is scanned afresh.
  class Scanner
    NAME = "SCANNER"
    GROUP = "scan"
    SYMBOLS = {
      "SCAN_TIMED_OUT" => [ 3.0, "Scan ran out of time" ],
      "SCAN_ERROR" => [ 3.0, "Scan failed" ]
    }.freeze

    # Every symbol a scan may fire, as /symbols lists them.
    attr_reader :catalogue

    def initialize(config, rules:, stats:, greylister: nil, reputation: nil, database: nil)
      @config = config
      @rules = rules
      @stats = stats
      @greylister = greylister
      @reputation = reputation
      @database = database
      catalogue = Rules.catalogue(Rules.scanned(rules), config:)
      @groups = catalogue.to_h { [ it[:name], it[:group] ] }
      @weights = catalogue.to_h { [ it[:name], it[:weight] ] }.except(Greylister::NAME)
      check_names
      @catalogue = catalogue.map { in_use(it) }
    end

    def check(message, envelope)
      hits, complete = run(message, envelope)
      hits = scored(hits.concat(Limits.hits(message)))
      hits.concat(scored(@reputation.hits(message, envelope, hits))) if @reputation
      hits = capped(hits)
      action = action_for(hits, complete)

      # Greylisting hook: greylist(message, envelope, action) returns nil to step aside, or [action, hit].
      if greylisting?(action, hits)
        action, hit = @greylister&.greylist(message, envelope, action) || action
        hits << hit if hit
      end

      verdict(action.nil? || action == "greylist" ? "no_action" : action, hits, complete, message)
    end

    def failed(message)
      hits = capped(scored([ hit("SCAN_ERROR") ]))
      action = action_for(hits, false)
      verdict(action.nil? || action == "greylist" ? "no_action" : action, hits, false, message)
    end

    private
      def check_names
        check_known(@config.scores.keys, @weights.keys, "symbol in scores")
        check_known(@config.groups.keys, Rules.groups, "group")
      end

      def check_known(names, known, kind)
        if (unknown = names - known).any?
          raise ConfigError, "unknown #{kind}: #{unknown.join(", ")}"
        end
      end

      # A symbol at the weight in use, or marked disabled when switched off.
      def in_use(symbol)
        if @config.scores.key?(symbol[:name])
          score = @config.scores[symbol[:name]]
          score ? symbol.merge(weight: score) : symbol.merge(disabled: true)
        else
          symbol
        end
      end

      def run(message, envelope)
        envelope = envelope.with(deadline: Envelope.now + @config.scan_budget, lookups: {})
        hits = []

        @rules.each do |rule|
          if envelope.remaining.zero?
            @stats.increment("budget_overruns")
            return [ hits << hit("SCAN_TIMED_OUT", rule::NAME), false ]
          end

          hits.concat(Array(run_rule(rule, message, envelope)))
        end

        [ hits, true ]
      end

      def run_rule(rule, message, envelope)
        rule.new(@config, @database).run(message, envelope)
      rescue => error
        @stats.increment("rule_errors")
        MailScore.logger.error "#{rule::NAME} raised #{error.class} queue_id=#{MailScore.log_field(envelope.queue_id)}"
        Hit.new(name: rule::ERROR, weight: rule::SYMBOLS.fetch(rule::ERROR).first) if rule.const_defined?(:ERROR)
      end

      def action_for(hits, complete)
        action = forced_action(hits) || @config.action_for(score_of(hits))
        !complete && @config.soft_reject_on_timeout && action != "reject" ? "soft_reject" : action
      end

      # A hit may force an action whatever the score, through its data, but
      # only an action the operator has left on.
      def forced_action(hits)
        hits.filter_map { it.data[:action] if it.data.is_a?(Hash) }.find { @config.thresholds[it] }
      end

      # Each hit at its symbol's weight from the scores setting, scaled as the
      # rule scaled the default, and none for a symbol switched off.
      def scored(hits)
        hits.filter_map do |hit|
          next hit unless @config.scores.key?(hit.name)

          score, default = @config.scores[hit.name], @weights.fetch(hit.name)
          hit.with(weight: default.zero? ? score : (hit.weight * score / default).round(2)) if score
        end
      end

      def hit(name, detail = nil)
        Hit.new(name:, weight: SYMBOLS.fetch(name).first, detail:)
      end

      # From the greylist threshold up, every action but reject.
      def greylisting?(action, hits)
        threshold = @config.thresholds["greylist"]
        threshold && action != "reject" && score_of(hits) >= threshold
      end

      # Group caps, in the order the hits fired: a hit that takes its
      # group's total past max_score, or a negative total below min_score,
      # adds what is left, and later hits of its sign add 0.
      def capped(hits)
        totals = Hash.new(0.0)

        hits.map do |hit|
          group = @groups[hit.name]
          weight = within(@config.groups[group], totals[group], hit.weight)
          totals[group] += weight
          weight == hit.weight ? hit : hit.with(weight:)
        end
      end

      # A cap of 0, or none, is no cap. What is left is rounded.
      def within(group, total, weight)
        max, min = group&.max_score, group&.min_score

        if weight.positive? && max&.positive?
          [ weight, (max - total).round(2) ].min.clamp(0.0..)
        elsif weight.negative? && min&.negative?
          [ weight, (min - total).round(2) ].max.clamp(..0.0)
        else
          weight
        end
      end

      def score_of(hits)
        hits.sum(0.0, &:weight).round(2)
      end

      def verdict(action, hits, complete, message)
        @stats.increment("scans_#{action}")
        Verdict.new(action:, score: score_of(hits), complete:, hits:,
          subject: Message.encode_words(@config.subject_template.sub("%s") { message.subject.to_s }))
      end
  end
end
