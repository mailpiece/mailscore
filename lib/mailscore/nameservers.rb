require "resolv"
require "socket"

module MailScore
  # The +nameservers+ setting as addresses, or nil for the system resolver.
  # An address passes as it is. A host name, such as a resolver's service
  # name inside Docker, is looked up through the system resolver at boot and
  # again in the background, so a resolver restarted with a new address is
  # picked up without a scan waiting on it.
  class Nameservers
    LOOKUP = ->(name) { Addrinfo.getaddrinfo(name, 53, nil, :DGRAM).map(&:ip_address).uniq }

    attr_reader :addresses

    def initialize(entries, lookup: LOOKUP)
      @entries = entries
      @lookup = lookup
    end

    # At boot: a name that doesn't resolve stops the daemon.
    def resolve
      @addresses = resolved
    rescue SocketError => error
      raise ConfigError, "nameservers: #{error.message}"
    end

    # Keeps the last addresses when a lookup fails.
    def refresh
      @addresses = resolved
    rescue SocketError => error
      MailScore.logger.warn "nameservers refresh failed: #{error.message}"
    end

    # Each worker refreshes its own copy, as the addresses aren't shared
    # across the fork.
    def refresh_every(seconds)
      return unless @entries

      Thread.new do
        loop do
          refresh
        rescue StandardError => error
          MailScore.logger.error "nameservers refresh failed: #{error.class}"
        ensure
          sleep seconds
        end
      end
    end

    private
      def resolved
        @entries&.flat_map { address?(it) ? [ it ] : @lookup.(it) }&.uniq
      end

      def address?(entry)
        Resolv::IPv4::Regex.match?(entry) || Resolv::IPv6::Regex.match?(entry)
      end
  end
end
