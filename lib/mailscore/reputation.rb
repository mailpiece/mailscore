require "digest"
require "mailauth"

module MailScore
  # How mail from the client IP, IPv6 as its /64, its DKIM signers and the SPF
  # record it passed has scored, and the IP's ASN and country when their
  # files are set. Each complete scan of an untrusted envelope folds its score
  # into a moving average for each selector, after the verdict, so a message
  # never scores itself. The score recorded leaves out the selector's own
  # symbol. A greylisted first attempt adds nothing; its retry records the
  # outcome. A selector scores once it has seen the minimum count of
  # messages. Learning does not feed reputation yet; it would call +record+.
  class Reputation
    NAME = "REPUTATION"

    SYMBOLS = {
      "IP_REPUTATION_SPAM" => [ 3.0, "Sending IP mostly sends spam" ],
      "IP_REPUTATION_HAM" => [ -1.0, "Sending IP mostly sends good mail" ],
      "DKIM_REPUTATION_SPAM" => [ 3.0, "DKIM signer mostly sends spam" ],
      "DKIM_REPUTATION_HAM" => [ -1.0, "DKIM signer mostly sends good mail" ],
      "SPF_REPUTATION_SPAM" => [ 3.0, "SPF record mostly passes spam" ],
      "SPF_REPUTATION_HAM" => [ -1.0, "SPF record mostly passes good mail" ]
    }.freeze

    PREFIXES = { "ip" => "IP_REPUTATION", "asn" => "IP_REPUTATION", "country" => "IP_REPUTATION", "dkim" => "DKIM_REPUTATION", "spf" => "SPF_REPUTATION" }.freeze
    # What the ASN and the country add to the IP's score; the others count whole.
    FACTORS = { "asn" => 0.4, "country" => 0.01 }.freeze

    # The average moves toward each new score by 1 - e^(-elapsed / window).
    UPSERT = <<~SQL
      INSERT INTO reputation (selector, value, score, count, updated_at, expires_at) VALUES (?1, ?2, ?3, 1, ?4, ?5)
      ON CONFLICT (selector, value) DO UPDATE SET
        score = score + (1 - exp(-max(excluded.updated_at - updated_at, 0) / ?6)) * (excluded.score - score),
        count = count + 1,
        updated_at = max(updated_at, excluded.updated_at),
        expires_at = max(expires_at, excluded.expires_at)
    SQL

    # tanh(average / reject × atanh(0.95) − atanh(0.5)): an average of 0 scores
    # -0.5 and one at the reject threshold 0.86.
    STRETCH = 1.83178
    OFFSET = 0.5493
    REJECT = 10.0 # the threshold when reject is off

    def initialize(config, database)
      @config = config
      @database = database
      @origin = Origin.new(asn_database: config.asn_database, country_database: config.country_database)
    end

    # A hit for each symbol with enough history behind it. The IP's ASN and
    # country add to its score by their factors, and the DKIM signers add up
    # to one score held between -1 and 1.
    def hits(message, envelope, hits, now: Time.now)
      return [] if envelope.trusted?

      scores = selectors(envelope, hits).filter_map { |selector, value| score(selector, value) }
      scores.group_by { PREFIXES.fetch(it.first) }.filter_map { |prefix, group| hit(prefix, group) }
    end

    def record(message, envelope, verdict, now: Time.now)
      return if !verdict.complete || verdict.greylisted? || envelope.trusted?

      total = verdict.hits.sum(0.0, &:weight)
      expires_at = (now.to_i + @config.reputation_expiry).ceil

      @database.transaction do
        selectors(envelope, verdict.hits).each do |selector, value|
          score = total - own_weight(verdict.hits, PREFIXES.fetch(selector))
          @database.execute(UPSERT, selector, value, score, now.to_i, expires_at, @config.reputation_window.to_f)
        end
      end
    end

    private
      def own_weight(hits, prefix)
        hits.select { SYMBOLS.key?(it.name) && it.name.start_with?("#{prefix}_") }.sum(0.0, &:weight)
      end

      def selectors(envelope, hits)
        address = envelope.address
        ip = address&.ipv4? ? address : address&.mask(64)

        [ [ "ip", ip&.to_s ], [ "asn", address && @origin.asn(address) ], [ "country", address && @origin.country(address) ],
          *dkim(hits).map { [ "dkim", it ] }, [ "spf", spf(hits) ] ].select(&:last)
      end

      # The organizational domain of each DKIM signer that passed, aligned
      # with the From domain or not, as the Authentication rule's hit lists
      # them in its data.
      def dkim(hits)
        signers = Array(hits.find { it.name == "DKIM_PASS" }&.data)
        signers.map { MailAuth::Dmarc::OrganizationalDomain.of(it) }.uniq
      end

      # A hash of the SPF record that passed, the Authentication rule's hit's
      # data, so every domain publishing one record shares its reputation.
      # Without a record, or with an excluded one, there is none. A pass by
      # +all is SPF_ALLOWS_ANYONE instead, and vouches for nobody.
      def spf(hits)
        record = hits.find { it.name == "SPF_PASS" }&.data
        key = Digest::SHA256.hexdigest(record)[0, 32] if record
        key unless @config.spf_reputation_exclusions.include?(key)
      end

      # The average stretched over the reject threshold, once the selector has
      # seen the minimum count.
      def score(selector, value)
        if row = @database.execute("SELECT score, count FROM reputation WHERE selector = ? AND value = ?", selector, value).first
          average, count = row
          reject = @config.thresholds["reject"] || REJECT
          [ selector, value, Math.tanh(average / reject * STRETCH - OFFSET), count ] if count >= @config.reputation_min_count
        end
      end

      def hit(prefix, scores)
        score = scores.sum { |selector, _, own| own * FACTORS.fetch(selector, 1.0) }
        score = score.clamp(-1.0, 1.0) if prefix == "DKIM_REPUTATION"

        if score.abs > 0.001
          name = "#{prefix}_#{score.positive? ? "SPAM" : "HAM"}"
          detail = scores.map { |_, value, own, count| "#{value} score=#{own.round(2)} count=#{count}" }.join(", ")
          Hit.new(name:, weight: (SYMBOLS.fetch(name).first.abs * score).round(2), detail:)
        end
      end
  end
end
