require "maxmind/db"

module MailScore
  # The autonomous system and country a client IP is registered to, read from
  # MaxMind-format files the operator downloads, such as GeoLite2-ASN and
  # GeoLite2-Country. Either file is optional; without it the answer is nil.
  # Each process opens the files on first use, after the fork.
  class Origin
    def initialize(asn_database: nil, country_database: nil)
      @paths = { asn: asn_database, country: country_database }
      @readers = {}
      @mutex = Mutex.new
    end

    # "AS" and the number, such as "AS64500".
    def asn(address)
      lookup(:asn, address)&.dig("autonomous_system_number")&.then { "AS#{it}" }
    end

    # The ISO code of the country the network is registered in, such as "NL".
    def country(address)
      lookup(:country, address)&.dig("registered_country", "iso_code")
    end

    private
      def lookup(name, address)
        reader(name)&.get(address)
      end

      def reader(name)
        if @paths[name]
          @mutex.synchronize { @readers[name] ||= MaxMind::DB.new(@paths[name], mode: MaxMind::DB::MODE_FILE) }
        end
      end
  end
end
