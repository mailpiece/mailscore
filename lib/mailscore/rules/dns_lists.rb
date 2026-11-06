module MailScore
  module Rules
    # The DNS lists the +dnsbl+ and +uribl+ settings name, each asked about
    # what its checks find in the message and the session, unless it skips
    # the sender or its probe has it offline.
    # Lists that +is_whitelist+ are asked first, and what they allow the
    # others are not asked about. Their symbols are in the dnsbl and uribl
    # groups.
    class DnsLists < Rule
      NAME = "DNS_LISTS"
      GROUPS = %w[ dnsbl uribl ].freeze
      SYMBOLS = {}.freeze

      def self.symbols(config)
        GROUPS.each_with_object({}) do |group, symbols|
          config.public_send(group).each do |list|
            list.symbols.each { |name, (weight, description)| symbols[name] = [ weight, description, group ] }
          end
        end
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

        DnsList.hits(fired)
      end
    end
  end
end
