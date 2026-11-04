require "ipaddr"
require "yaml"

module MailScore
  class DnsList
    # Reads the +dnsbl+ and +uribl+ settings into lists, raising ConfigError
    # for anything malformed or a symbol named twice. +rspamd+ is the lists
    # Rspamd asks by default.
    module Parser
      SYMBOL = /\A[A-Z][A-Z0-9_]*\z/
      SWITCHES = { "unknown" => true, "ipv4" => true, "ipv6" => true, "no_ip" => false, "url_full_hostname" => false,
        "emails_domainonly" => false, "dkim_domainonly" => true, "is_whitelist" => false, "ignore_whitelist" => false,
        "exclude_users" => true, "exclude_local" => true, "disable_monitoring" => false }.freeze
      MONITORED_ADDRESS = "1.0.0.127"
      REQUESTS_LIMIT = 64
      HASHES = %w[ md5 sha1 sha256 sha384 sha512 blake2 ].freeze
      HASH_FORMATS = %w[ hex base32 base64 ].freeze
      RSPAMD = YAML.safe_load_file(File.join(__dir__, "rspamd.yml")).freeze

      def self.parse(lists, key, checks:)
        lists = RSPAMD.fetch(key) if lists == "rspamd"
        raise ConfigError, "#{key} must be rspamd or a list of zones" unless lists.is_a?(Array)

        lists = lists.each_with_index.map { |list, index| list(list, "#{key}[#{index}]", checks) }
        symbols = lists.flat_map { it.symbols.keys }
        raise ConfigError, "#{key} names a symbol twice" unless symbols == symbols.uniq && lists.none? { it.returns.map(&:symbol).include?(it.failure_symbol) }
        lists
      end

      def self.list(list, name, checks)
        raise ConfigError, "#{name} must be a mapping" unless list.is_a?(Hash)

        required = %w[ zone symbol weight ]
        optional = %w[ returncodes returnbits whitelist_exception checks requests_limit prefixes hash hash_len hash_format emails_delimiter
          monitored_address random_monitored ] + SWITCHES.keys
        if (unknown = list.keys - required - optional).any?
          raise ConfigError, "unknown #{name} setting: #{unknown.join(", ")}"
        end
        if (missing = required - list.keys).any?
          raise ConfigError, "missing #{name} setting: #{missing.join(", ")}"
        end

        raise ConfigError, "#{name}.zone must be a non-empty string" unless list["zone"].is_a?(String) && !list["zone"].empty?
        patterns = Array(list["returncodes"]&.values).any? { |codes| codes.is_a?(Hash) && Array(codes["codes"]).any? { Pattern.pattern?(it.to_s) } }

        checks = checks(list.fetch("checks", checks), "#{name}.checks")
        prefixes = prefixes(list.fetch("prefixes", {}), checks, "#{name}.prefixes")
        switches = SWITCHES.to_h { |switch, default| [ switch.to_sym, switch(list.fetch(switch, default), "#{name}.#{switch}") ] }
        # Rspamd probes a random name of a list not asked about addresses
        random_monitored = (checks & %w[ from received ]).empty? || switches[:no_ip]

        DnsList.new \
          zone: list["zone"].downcase.delete_suffix("."),
          symbol: symbol(list["symbol"], "#{name}.symbol"),
          weight: weight(list["weight"], "#{name}.weight", prefixes),
          returns: returns(list.fetch("returncodes", {}), "#{name}.returncodes", "codes", patterns:, prefixes:) +
            returns(list.fetch("returnbits", {}), "#{name}.returnbits", "bit", patterns:, prefixes:),
          whitelist_exception: symbols(list.fetch("whitelist_exception", []), "#{name}.whitelist_exception"),
          checks:,
          prefixes:,
          digest: one_of(list["hash"], HASHES, "#{name}.hash"),
          hash_len: list["hash_len"].nil? ? nil : limit(list["hash_len"], "#{name}.hash_len"),
          hash_format: one_of(list.fetch("hash_format", "hex"), HASH_FORMATS, "#{name}.hash_format"),
          emails_delimiter: list["emails_delimiter"].nil? ? nil : delimiter(list["emails_delimiter"], "#{name}.emails_delimiter"),
          requests_limit: limit(list.fetch("requests_limit", REQUESTS_LIMIT), "#{name}.requests_limit"),
          monitored_address: monitored_address(list.fetch("monitored_address", MONITORED_ADDRESS), "#{name}.monitored_address"),
          random_monitored: switch(list.fetch("random_monitored", random_monitored), "#{name}.random_monitored"),
          **switches
      end

      def self.checks(value, key)
        raise ConfigError, "#{key} must be a list of #{CHECKS.join(", ")}" unless value.is_a?(Array) && value.any? && (value - CHECKS).empty?
        value.uniq
      end

      # A symbol prefix for each check, such as CLIENT for from and RECEIVED
      # for received, and then one for every check.
      def self.prefixes(value, checks, key)
        valid = value.is_a?(Hash) && (value.empty? || value.keys.sort == checks.sort) && value.values.all? { it.to_s.match?(SYMBOL) }
        raise ConfigError, "#{key} must name a symbol prefix for each check" unless valid
        value
      end

      def self.one_of(value, values, key)
        raise ConfigError, "#{key} must be one of #{values.join(", ")}" unless value.nil? || values.include?(value)
        value
      end

      def self.delimiter(value, key)
        raise ConfigError, "#{key} must be a string" unless value.is_a?(String)
        value
      end

      def self.monitored_address(value, key)
        raise ConfigError, "#{key} must be a DNS name" unless value.is_a?(String) && DnsList.valid_name?(value)
        value
      end

      def self.limit(value, key)
        raise ConfigError, "#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?
        value
      end

      def self.returns(value, key, by, patterns:, prefixes:)
        raise ConfigError, "#{key} must be a mapping" unless value.is_a?(Hash)

        value.map do |name, settings|
          valid = settings.is_a?(Hash) && settings.keys.sort == [ by, "weight" ].sort && weight?(settings["weight"], prefixes) &&
            (by == "bit" ? settings["bit"].is_a?(Integer) && settings["bit"].positive? : codes?(settings["codes"], patterns:))
          raise ConfigError, "#{key}.#{name} must have a weight and #{by == "bit" ? "a positive bit" : "IPv4 codes or patterns"}" unless valid

          codes = Array(settings["codes"])
          Return.new(symbol: symbol(name, "#{key}.#{name}"), weight: floats(settings["weight"]), codes:,
            matchers: patterns ? codes.map { Pattern.regexp(it) } : codes, bit: settings["bit"])
        end
      end

      def self.codes?(codes, patterns:)
        Array(codes).any? && Array(codes).all? do |code|
          code.is_a?(String) && (patterns ? Pattern.regexp(code) : IPAddr.new(code).ipv4?)
        end
      rescue IPAddr::Error, ArgumentError, RegexpError
        false
      end

      def self.symbol(value, key)
        raise ConfigError, "#{key} must be a symbol name in capitals" unless value.to_s.match?(SYMBOL)
        value
      end

      def self.symbols(value, key)
        raise ConfigError, "#{key} must be a list of symbol names" unless value.is_a?(Array) && value.all? { it.to_s.match?(SYMBOL) }
        value
      end

      # A number, or with prefixes a number for each prefix.
      def self.weight(value, key, prefixes)
        raise ConfigError, "#{key} must be #{prefixes.empty? ? "a number" : "a number for each prefix"}" unless weight?(value, prefixes)
        floats(value)
      end

      def self.floats(weight)
        weight.is_a?(Hash) ? weight.transform_values(&:to_f) : weight.to_f
      end

      def self.weight?(value, prefixes)
        if prefixes.empty?
          value.is_a?(Numeric)
        else
          value.is_a?(Hash) && value.keys.sort == prefixes.values.uniq.sort && value.values.all?(Numeric)
        end
      end

      def self.switch(value, key)
        raise ConfigError, "#{key} must be on or off" unless value == true || value == false
        value
      end
    end
  end
end
