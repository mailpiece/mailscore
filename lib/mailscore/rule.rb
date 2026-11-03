module MailScore
  # What every rule inherits: the scanner builds each one per scan as
  # +rule.new(config, database)+. +dns+ replaces the network, such as with
  # a fake zone in tests.
  class Rule
    def initialize(config, database, dns: nil)
      @config = config
      @database = database
      @dns = dns
    end

    private
      def resolver(envelope)
        Resolver.new(envelope, dns: @dns)
      end
  end
end
