require "mailresolver"

module MailScore
  # DNS for one scan. No lookup starts past the scan's deadline, and each one
  # gets mailresolver's timeouts scaled down to fit the time left, asking the
  # nameservers set at boot. A budget too far spent to scale to timeouts
  # above zero skips the lookup as timed out. +dns+ replaces the network,
  # such as with a fake zone in tests.
  class Resolver
    def initialize(envelope, dns: nil)
      @envelope = envelope
      @dns = dns
    end

    def txt(name)
      lookup(:txt, name)
    end

    def a(name)
      lookup(:a, name)
    end

    def aaaa(name)
      lookup(:aaaa, name)
    end

    def addresses(name)
      lookup(:addresses, name)
    end

    def mx(name)
      lookup(:mx, name)
    end

    def ptr(address)
      lookup(:ptr, address)
    end

    def cname(name)
      lookup(:cname, name)
    end

    def ns(name)
      lookup(:ns, name)
    end

    private
      def lookup(type, name)
        timeouts = timeouts(@envelope.remaining)
        raise MailResolver::Timeout, "scan budget spent before #{type.upcase} #{name.to_s.inspect}" unless timeouts.all?(&:positive?)

        (@dns || MailResolver::Resolver.new(timeouts:, nameservers: MailScore.nameservers.addresses)).public_send(type, name)
      end

      def timeouts(remaining)
        scale = [ remaining / MailResolver::Resolver::TIMEOUTS.sum, 1 ].min
        MailResolver::Resolver::TIMEOUTS.map { it * scale }
      end
  end
end
