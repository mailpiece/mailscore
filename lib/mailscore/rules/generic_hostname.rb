module MailScore
  module Rules
    # A client whose host name or HELO reads like a home or dynamic line,
    # such as 203-0-113-9.dsl.example.net, which a mail server rarely has.
    # Each pattern has a likelihood, and only the likeliest name fires: the
    # HELO's on a tie. A bare address in HELO is HeloBareIp's, and a HELO
    # without a dot HeloNotFqdn's.
    class GenericHostname < Rule
      NAME = "GENERIC_HOSTNAME"
      GROUP = "hostname"

      LEVELS = %w[ VERY_LOW LOW MEDIUM HIGH VERY_HIGH ].freeze
      SYMBOLS = { "HOSTNAME" => "Host name", "HELO" => "Server greeting" }.flat_map do |kind, label|
        LEVELS.map { [ "#{kind}_GENERIC_#{it}", [ 0.0, "#{label} looks dynamic, #{it.tr("_", " ").downcase} likelihood" ] ] }
      end.to_h.freeze

      # Likelihood, from 5 down, to what a name holds anywhere in it.
      PATTERNS = {
        5 => %w[
          [-.0-9][0-9][.-]?nat homeuser[.-][0-9] [-.0-9][0-9][.-]?pppoe [-.0-9][0-9][.-]?dynamic [.-]catv[.-] comcast[.-][0-9] [.-]broadband[.-] [.-]homeuser[.-]
          [-.0-9][0-9][.-]?catv [.-]wifi[.-] dynip[.-][0-9] [.-]broad[.-] [-.0-9][0-9][.-]?ppp [.-]nat[.-] gprs[.-][0-9] brodband[.-][0-9]
          [.-]gprs[.-] dynamic[.-][0-9] [.-]cdma[.-] ppp[.-][0-9] dhcp[.-][0-9] clients?[.-][0-9]{2,} [.-]ppp[.-] [.-]dhcp[.-]
          [-.0-9][0-9][.-]?dial-?up [-.0-9][0-9][.-]?bredband [.-]dial-?up[.-] [.-]cablemodem[.-] pppoe[.-][0-9] pptp[.-][0-9] broadband[.-][0-9] [-.0-9][0-9][.-]?comcast
          [.-]dynamic[.-] cdma[.-][0-9] [0-9][.-]?broad catv[.-][0-9] [-.0-9][0-9][.-]?homeuser [-.0-9][.-]pppoe[.-] [-.0-9][.-]dynip[.-] [-.0-9][0-9]{3,}[.-]?clients?
          [-.0-9][0-9][.-]?pptp [-.0-9][0-9][.-]?[ax]?dsl-dynamic dial-?up[.-][0-9] [-.0-9][0-9][.-]?cablemodem [ax]?dsl-dynamic[.-]?[0-9] [.-]pptp[.-] [.-][ax]?dsl-dynamic[.-] [0-9][.-]?wifi
          dyn[.-][0-9][-.0-9] [-.0-9][0-9][.-]broadband broad[.-][0-9] [-.0-9][0-9][.-]gprs cablemodem[.-][0-9] [-.0-9][0-9][.-]modem [-.0-9][0-9][.-]dyn [-.0-9][0-9][.-]dynip
          [-.0-9][0-9][.-]cdma [.-]modem[.-] nat[.-][0-9] [.-]bredband[.-] modem[.-][0-9] [0-9][.-]?dhcp wifi[.-][0-9]
        ],
        4 => %w[
          [0-9][.-]?fbx [ax]?dsl-line[.-]?[0-9] pool[.-][0-9] [-.0-9][0-9][.-]?in-?addr [.-]fbx[.-] [-.0-9][0-9][.-]?pool [-.0-9][0-9][.-]?[ax]?dsl-line [.-][ax]?dsl-line[.-]
          [-.0-9][0-9][.-]?fibertel fbx[.-][0-9] [-.0-9][0-9][.-]?[ax]?dsl [.-]in-?addr[.-] [.-]pool[.-] [ax]?dsl[.-]?[0-9] [.-][ax]?dsl[.-] fibertel[.-][0-9]
          in-?addr[.-][0-9] [.-]fibertel[.-]
        ],
        3 => %w[
          [-.0-9][0-9][.-]?unused-addr unused-addr[.-][0-9] [0-9][.-]?kabel kabel[.-][0-9] cable[.-][0-9] [.-]unused-addr[.-] [-.0-9][0-9][.-]cable [.-]kabel[.-]
          [.-]cable[.-]
        ],
        2 => %w[ [.-]host[.-] [-.0-9][0-9][.-]?host host[.-][0-9] ],
        1 => %w[
          [.-]peer[.-] customers?[.-][0-9] [.-]user[.-] [-.0-9][0-9][.-]?peer [-.0-9][0-9][.-]?user user[.-][0-9] [-.0-9][0-9][.-]?customers? peer[.-][0-9]
          [.-]customers?[.-] [.-]clients?[.-] [.-]vps[.-]
        ]
      }.transform_values { Regexp.new(it.join("|"), Regexp::IGNORECASE) }.freeze

      # What only a HELO gives away: a home router's or a private network's name.
      HELO_PATTERN = /\A(?:dsl)?(?:device|speedtouch)\.lan\z|\.(?:lan|local|home|localdomain|intra|in-addr\.arpa|priv|user|veloxzon)\z/i

      def run(_message, envelope)
        return if envelope.trusted?

        helo = helo_level(envelope.helo)
        hostname = hostname(envelope)&.then { [ level(it), it ] }

        if helo && (hostname.nil? || helo.first >= hostname.first)
          hit("HELO", *helo)
        elsif hostname && hostname.first.positive?
          hit("HOSTNAME", *hostname)
        end
      end

      private
        # The caller's Hostname, or else the first name mailscore's own PTR
        # lookup gave, unchecked. nil when the client has none.
        def hostname(envelope)
          envelope.client_hostname(resolver(envelope))&.then { it unless it.casecmp?("unknown") }
        end

        def helo_level(helo)
          return if helo.nil? || HeloBareIp.bare?(helo) || !helo.include?(".")

          level = helo.chomp(".").match?(HELO_PATTERN) ? 5 : level(helo)
          [ level, helo ] if level.positive?
        end

        def level(name)
          PATTERNS.find { |_, pattern| name.match?(pattern) }&.first || 0
        end

        def hit(kind, level, name)
          symbol = "#{kind}_GENERIC_#{LEVELS[level - 1]}"
          Hit.new(name: symbol, weight: SYMBOLS.fetch(symbol).first, detail: name)
        end
    end
  end
end
