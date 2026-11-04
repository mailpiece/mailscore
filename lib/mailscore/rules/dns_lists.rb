module MailScore
  module Rules
    # The DNS lists the +dnsbl+ and +uribl+ settings name, each asked about
    # what its checks find in the message and the session, unless it skips
    # the sender or its probe has it offline.
    # Lists that +is_whitelist+ are asked first, and what they allow the
    # others are not asked about. The +uribl+ lists' hits weigh at most
    # URIBL_MAX_WEIGHT together.
    class DnsLists < Rule
      NAME = "DNS_LISTS"
      SYMBOLS = {}.freeze
      URIBL_MAX_WEIGHT = 12.5

      def self.symbols(config)
        [ *config.dnsbl, *config.uribl ].map(&:symbols).reduce({}, :merge)
      end

      def run(message, envelope)
        lists = [ *@config.dnsbl, *@config.uribl ].reject { it.skips?(envelope) || it.offline? }
        return [] if lists.empty?

        resolver = resolver(envelope)
        candidates = DnsList::Candidates.new(message, envelope, resolver)
        allowing, others = lists.partition(&:is_whitelist)

        fired = DnsList.fire(allowing.flat_map { it.queries(candidates.for(it), []) }, resolver, envelope)
        allowed = fired.select { it.query.list.allows?(it) }.flat_map { it.query.origins }
        fired += DnsList.fire(others.flat_map { it.queries(candidates.for(it), allowed) }, resolver, envelope)

        uribl, dnsbl = fired.partition { @config.uribl.include?(it.query.list) }
        [ *DnsList.hits(dnsbl), *capped(DnsList.hits(uribl)) ]
      end

      private
        def capped(hits)
          total = 0.0

          hits.map do |hit|
            next hit unless hit.weight.positive?

            weight = [ hit.weight, URIBL_MAX_WEIGHT - total ].min
            total += weight
            hit.with(weight:)
          end
        end
    end
  end
end
