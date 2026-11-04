require "mailauth"

module MailScore
  module Rules
    # SPF, DKIM, DMARC and ARC, checked once per scan, with a hit for each.
    # SPF checks the caller's envelope sender, or postmaster@HELO for <>.
    # Without a client IP or a From header, SPF and the DMARC that leans on
    # it are skipped; a trusted sender skips DKIM too. ARC always runs. A
    # From with no single domain fires FROM_UNREADABLE in DMARC's place. When
    # the checks raise, ERROR fires in place of every hit.
    class Authentication < Rule
      NAME = "AUTHENTICATION"
      GROUP = "policies"
      ERROR = "AUTHENTICATION_ERROR"

      SYMBOLS = {
        "SPF_PASS" => [ -0.2, "SPF passed" ],
        "SPF_FAIL" => [ 1.0, "SPF failed" ],
        "SPF_SOFTFAIL" => [ 0.0, "SPF soft-failed" ],
        "SPF_NEUTRAL" => [ 0.0, "SPF neither allows nor forbids the server" ],
        "SPF_NONE" => [ 0.0, "No SPF record" ],
        "SPF_LOOKUP_FAILED" => [ 0.0, "SPF lookup failed" ],
        "SPF_INVALID" => [ 0.0, "Broken SPF record" ],
        "SPF_ALLOWS_ANYONE" => [ 4.0, "SPF record lets anyone send" ],
        "DKIM_PASS" => [ -0.1, "DKIM signature valid" ],
        "DKIM_FAIL" => [ 1.0, "DKIM signature failed" ],
        "DKIM_LOOKUP_FAILED" => [ 0.0, "DKIM key lookup failed" ],
        "DKIM_INVALID" => [ 0.0, "Broken DKIM signature or key" ],
        "DKIM_NONE" => [ 0.0, "No DKIM signature" ],
        "DKIM_PARTIAL_BODY" => [ 0.5, "DKIM signs only part of the body" ],
        "DMARC_PASS" => [ -0.5, "DMARC passed" ],
        # A spoof still reaches greylist under p=reject past every credit a
        # sender can earn for itself: SPF and DKIM passes for its own domain,
        # its own ARC seal and a bounce.
        "DMARC_FAIL_REJECT_POLICY" => [ 5.5, "DMARC failed under a reject policy" ],
        "DMARC_FAIL_QUARANTINE_POLICY" => [ 4.0, "DMARC failed under a quarantine policy" ],
        "DMARC_FAIL_NONE_POLICY" => [ 0.1, "DMARC failed under a monitoring policy" ],
        "DMARC_NONE" => [ 0.0, "No DMARC record" ],
        # One From field with no single domain DMARC can check, such as an
        # address only in a quoted name: honest mail never sends one, and it
        # shows a reader a sender no check can hold to account, so it weighs
        # just under FROM_MULTIPLE_ADDRESSES (8.0), which shows several.
        # Several addresses are FROM_MULTIPLE_ADDRESSES, none FROM_MISSING.
        "FROM_UNREADABLE" => [ 7.5, "From has no checkable domain" ],
        "DMARC_LOOKUP_FAILED" => [ 0.0, "DMARC lookup failed" ],
        "ARC_PASS" => [ -1.0, "ARC chain valid" ],
        "ARC_FAIL" => [ 1.0, "ARC chain broken" ],
        "ARC_INVALID" => [ 0.5, "Malformed ARC headers" ],
        "ARC_NONE" => [ 0.0, "No ARC chain" ],
        "AUTHENTICATION_ERROR" => [ 2.0, "SPF, DKIM, DMARC and ARC failed to run" ]
      }.freeze

      SPF = { "pass" => "SPF_PASS", "fail" => "SPF_FAIL", "softfail" => "SPF_SOFTFAIL", "neutral" => "SPF_NEUTRAL",
        "none" => "SPF_NONE", "temperror" => "SPF_LOOKUP_FAILED", "permerror" => "SPF_INVALID" }.freeze
      DKIM = { "pass" => "DKIM_PASS", "fail" => "DKIM_FAIL", "temperror" => "DKIM_LOOKUP_FAILED", "permerror" => "DKIM_INVALID" }.freeze
      DMARC_FAILURES = { "reject" => "DMARC_FAIL_REJECT_POLICY", "quarantine" => "DMARC_FAIL_QUARANTINE_POLICY", "none" => "DMARC_FAIL_NONE_POLICY" }.freeze
      OUT_OF_SAMPLE = { "reject" => "quarantine", "quarantine" => "none", "none" => "none" }.freeze

      def initialize(config, database, dns: nil, random: Random)
        super(config, database, dns:)
        @random = random
      end

      def run(message, envelope)
        resolver = resolver(envelope)
        mail = MailAuth::Message.new(message.raw)
        ip = envelope.address&.to_s

        spf = MailAuth::Spf.check(ip:, helo: envelope.helo, mail_from: envelope.mail_from, resolver:) if ip && envelope.mail_from && !envelope.trusted?
        dkim = envelope.lookups[:dkim] ||= MailAuth::Dkim.verify(mail, resolver:) unless envelope.trusted?
        domain = mail.header_from_domain
        dmarc = MailAuth::Dmarc.check(header_from: domain, spf:, dkim: Authentication.credited(dkim), resolver:) if spf && domain
        from_unreadable = hit("FROM_UNREADABLE", nil) if spf && !domain && one_from?(message)
        arc = MailAuth::Arc.verify(mail, resolver:)

        [ spf&.then { spf_hit(it) }, dkim&.then { dkim_hit(it) }, dmarc&.then { dmarc_hit(it, domain) }, from_unreadable, arc_hit(arc, mail) ].compact
      end

      # The signatures that vouch for the message: not a pass whose l= leaves
      # part of the body unsigned, where anything may be appended.
      def self.credited(dkim)
        dkim && MailAuth::DkimResult.new(signatures: dkim.signatures.reject { it.status == "pass" && it.under_sized })
      end

      private
        # One From field with at most one address in it, which FROM_MISSING
        # and FROM_MULTIPLE_ADDRESSES leave alone.
        def one_from?(message)
          fields = message.header_values("from")
          fields.one? && !fields.first.strip.empty? && message.from_addresses.size < 2
        end

        # A pass from a record that lets any host send vouches for nobody, so
        # it is not SPF_PASS. DMARC still reads it as the pass it is. The
        # detail is the domain checked, then its record when it has one, and
        # the record is the hit's data for reputation.
        def spf_hit(spf)
          plus_all = spf.status == "pass" && spf.allows_any
          hit plus_all ? "SPF_ALLOWS_ANYONE" : SPF.fetch(spf.status), [ spf.domain, spf.record ].compact.join(" ").then { it unless it.empty? },
            data: spf.record
        end

        # The signers' domains are the detail and, as a list, the hit's data
        # for reputation. A d= that is not a host name, such as one that
        # holds a comma, never passes, and is left out of a failure's detail.
        # A pass that covers part of the body alone is DKIM_PARTIAL_BODY, with
        # no data, so it earns no reputation.
        def dkim_hit(dkim)
          credited = Authentication.credited(dkim)

          if credited.status == "pass" || dkim.status != "pass"
            domains = (credited.status == "pass" ? credited.passing_domains : credited.signatures.filter_map(&:domain).select { MailAuth::Dkim.host_name?(it) }).uniq
            hit DKIM.fetch(credited.status, "DKIM_NONE"), domains.join(", ").then { it unless it.empty? }, data: domains
          else
            hit "DKIM_PARTIAL_BODY", dkim.passing_domains.uniq.join(", ").then { it unless it.empty? }
          end
        end

        def dmarc_hit(dmarc, domain)
          case dmarc.status
          when "pass" then hit "DMARC_PASS", domain
          when "fail"
            if sampled?(dmarc)
              hit DMARC_FAILURES.fetch(dmarc.policy), "#{domain} p=#{dmarc.policy}"
            else
              hit DMARC_FAILURES.fetch(OUT_OF_SAMPLE.fetch(dmarc.policy)), "#{domain} p=#{dmarc.policy} pct=#{dmarc.pct}"
            end
          when "temperror" then hit "DMARC_LOOKUP_FAILED", domain
          else hit "DMARC_NONE", domain
          end
        end

        def sampled?(dmarc)
          dmarc.pct >= 100 || @random.rand(100) < dmarc.pct
        end

        def arc_hit(arc, message)
          case arc.status
          when "pass" then hit "ARC_PASS", arc.sealers.join(", ").then { it unless it.empty? }
          when "fail" then arc_failure(arc, message)
          else hit "ARC_NONE", nil
          end
        end

        # Malformed sets are invalid, unless a hop past the first saw the chain
        # broken. Every other failure rejects, a key lookup that failed too.
        def arc_failure(arc, message)
          error = MailAuth::Arc::Chain.new(message).structural_error
          rejected = arc.sets.any? { it.instance > 1 && it.chain_status && it.chain_status != "pass" }

          if error && !rejected
            hit "ARC_INVALID", error
          else
            hit "ARC_FAIL", arc.comment
          end
        end

        def hit(name, detail, data: nil)
          Hit.new(name:, weight: SYMBOLS.fetch(name).first, detail:, data:)
        end
    end
  end
end
