module MailScore
  module Rules
    # The DNS lists the +dnsbl+ and +uribl+ settings name, each asked about
    # what its checks find in the message and the session, unless it skips
    # the sender.
    # Lists that +is_whitelist+ are asked first, and what they allow the
    # others are not asked about. Their symbols are in the rbl and surbl
    # groups.
    class DnsLists < Rule
      NAME = "DNS_LISTS"
      GROUPS = { "dnsbl" => "rbl", "uribl" => "surbl" }.freeze
      SYMBOLS = {}.freeze

      def self.symbols(config)
        GROUPS.each_with_object({}) do |(setting, group), symbols|
          config.public_send(setting).each do |list|
            list.symbols.each { |name, (weight, description)| symbols[name] = [ weight, description, group ] }
          end
        end
      end

      def run(message, envelope)
        lists = [ *@config.dnsbl, *@config.uribl ].reject { it.skips?(envelope) }
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
