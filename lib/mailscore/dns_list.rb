require "ipaddr"
require "mailresolver"
require "openssl"

module MailScore
  # A DNS list from the config: the zone to ask, the symbol and weight a
  # listing fires, and +returns+ that name some answers more precisely, by
  # their codes or by a bit they carry. An answer no return names fires the
  # list's own symbol when +unknown+ is set. +checks+ say what the list is
  # asked about, at most +requests_limit+ URLs and as many addresses from
  # the text, and the top +received_max_pos+ Received headers. +ipv4+ and
  # +ipv6+ say which client addresses it takes, +no_ip+ keeps URL hosts
  # that are addresses from it, and +url_full_hostname+,
  # +emails_domainonly+ and +dkim_domainonly+ how a name is asked. A list
  # with a +digest+ is asked a name's digest in +hash_format+, cut to
  # +hash_len+. +prefixes+ name each check's symbols, such as CLIENT_ for
  # from and RECEIVED_ for received, and then each weight is a number per
  # prefix. A list that +is_whitelist+ is asked first, and what its returns
  # name, short of +whitelist_exception+, the other lists are not asked
  # about the same way, unless they +ignore_whitelist+. A list that says
  # +exclude_users+ skips authenticated senders, and +exclude_local+ the
  # local networks.
  DnsList = Data.define(:zone, :symbol, :weight, :returns, :unknown, :checks, :prefixes, :requests_limit, :received_max_pos, :ipv4, :ipv6, :no_ip,
    :url_full_hostname, :emails_domainonly, :emails_delimiter, :dkim_domainonly, :digest, :hash_len, :hash_format,
    :is_whitelist, :whitelist_exception, :ignore_whitelist, :exclude_users, :exclude_local)

  class DnsList
    # Lua-style patterns for return codes, such as 127%.0%.%d+%.1: %d for a
    # digit, %. for a dot, sets in brackets, a dot for any character, and
    # +, * and ? after them. A code is a pattern when it holds % or [.
    module Pattern
      CLASSES = { "d" => "0-9", "a" => "A-Za-z", "l" => "a-z", "u" => "A-Z", "w" => "A-Za-z0-9", "x" => "0-9A-Fa-f", "s" => "\\s" }.freeze

      def self.pattern?(code)
        code.match?(/[%\[]/)
      end

      def self.regexp(pattern)
        chars = pattern.chars
        source = +""

        until chars.empty?
          char = chars.shift
          source << case char
          when "%" then escape(chars.shift, set: false)
          when "[" then set(chars)
          when "." then "."
          when "-" then "*?"
          when "*", "+", "?" then char
          else Regexp.escape(char)
          end
        end

        Regexp.new("\\A(?:#{source})\\z")
      end

      def self.set(chars)
        source = +"["
        source << chars.shift if chars.first == "^"

        while (char = chars.shift) != "]"
          raise ArgumentError, "unclosed set" if char.nil?
          source << (char == "%" ? escape(chars.shift, set: true) : char == "-" ? "-" : Regexp.escape(char))
        end

        "#{source}]"
      end

      def self.escape(char, set:)
        raise ArgumentError, "% at the end" if char.nil?

        if (range = CLASSES[char])
          set ? range : "[#{range}]"
        elsif char.match?(/[[:alnum:]]/)
          raise ArgumentError, "unknown class %#{char}"
        else
          Regexp.escape(char)
        end
      end
    end

    # +codes+ as written, and +matchers+ to compare answers with: the codes
    # themselves, or regexps for a list whose codes are patterns.
    Return = Data.define(:symbol, :weight, :codes, :matchers, :bit) do
      def match?(answer, number)
        bit ? number && number & bit == bit : matchers.any? { it === answer }
      end
    end

    # One name asked of one list, on behalf of +origins+: each an address,
    # a domain or an email address, with the check that found it.
    Query = Data.define(:list, :origins, :name) do
      def detail(label = nil)
        origins.select { label.nil? || it.last == label }.map(&:first).uniq.join(", ")
      end
    end

    # A symbol a query fired, as named for the check that found it, with the
    # return or list symbol it stands for and the detail it adds.
    Fired = Data.define(:symbol, :base, :weight, :query, :detail)

    PARALLEL = 16
    NAME_LABEL = /(?![-])[A-Za-z0-9_-]{1,63}(?<![-])/
    CHECKS = %w[ from received helo rdns dkim emails replyto urls content_urls from_smtp from_mime mid ].freeze
    DIGESTS = { "md5" => "MD5", "sha1" => "SHA1", "sha256" => "SHA256", "sha384" => "SHA384", "sha512" => "SHA512", "blake2" => "BLAKE2b512" }.freeze
    ZBASE32 = "ybndrfg8ejkmcpqxot1uwisza345h769"
    # A zone label this long is a key, such as a Data Query Service's.
    KEY_LABEL = /\A[a-z0-9]{20,}\z/
    FAILURES = { MailResolver::Timeout => "timeout", MailResolver::ServerFailure => "server failure" }.freeze

    # The name to ask for an address: its octets, or its nibbles for IPv6,
    # in reverse under the zone.
    def self.reversed(address)
      address.reverse.sub(/\.(?:in-addr|ip6)\.arpa\z/, "")
    end

    # Asks every query, PARALLEL at a time, and returns what each fired, in
    # the order of the queries. A name not listed fires nothing, and a
    # lookup that timed out or failed fires the list's symbol with
    # _LOOKUP_FAILED, which weighs nothing. Once the scan's budget is spent,
    # the rest are not asked.
    def self.fire(queries, resolver, envelope)
      answers = ask(queries, resolver, envelope)

      queries.flat_map do |query|
        if (failure = FAILURES[answers[query].class])
          [ Fired.new(symbol: query.list.failure_symbol, base: query.list.failure_symbol, weight: 0.0, query:, detail: "#{query.detail} #{failure}") ]
        else
          Array(answers[query]).flat_map { query.list.fired(query, it) }
        end
      end
    end

    # One hit per symbol fired. Its detail is every origin that fired it,
    # with the answer when no return code or bit named it.
    def self.hits(fired)
      fired.group_by { [ it.symbol, it.weight ] }.map do |(name, weight), all|
        Hit.new(name:, weight:, detail: all.map(&:detail).uniq.join(", "))
      end
    end

    def self.ask(queries, resolver, envelope)
      queue = Queue.new
      queries.each { queue << it }
      queue.close

      Array.new([ PARALLEL, queries.size ].min) do
        Thread.new do
          Thread.current.report_on_exception = false
          answers = {}
          while (query = queue.pop)
            answers[query] = answer(query.name, resolver) unless envelope.remaining.zero?
          end
          answers
        end
      end.map(&:value).reduce({}, :merge)
    end

    # The list's answers, nil when the name is not listed, or the error.
    def self.answer(name, resolver)
      resolver.a(name)
    rescue MailResolver::NotFound
      nil
    rescue MailResolver::Error => error
      error
    end

    # The queries for +candidates+, each an origin, its check, the name to
    # ask and whether it is an address, one per name, leaving out the ones
    # +allowed+ spared. A name that is not an address is hashed when the
    # list says so; a digest, made here, is asked as it is, and any other
    # name only when it is valid. None is asked past 253 bytes with the zone.
    def queries(candidates, allowed)
      candidates = candidates.reject { |origin, label, _| allowed.include?([ origin, label ]) || allowed.include?([ origin.rpartition("@").last, label ]) } unless ignore_whitelist
      candidates.group_by { |_, _, name, address| address ? name : hashed(name) }.filter_map do |name, all|
        asked = "#{name}.#{zone}"
        Query.new(list: self, origins: all.map { it.first(2) }.uniq, name: asked) if (digest || DnsList.valid_name?(name)) && asked.bytesize <= 253
      end
    end

    # Labels of letters, digits, underscores and dashes joined by dots, none
    # empty, longer than 63 or starting or ending with a dash, so nothing a
    # resolver reads as an escape, such as a backslash, changes the labels.
    def self.valid_name?(name)
      name.match?(/\A#{NAME_LABEL}(?:\.#{NAME_LABEL})*\z/)
    end

    # +name+'s +digest+ in +hash_format+, cut to +hash_len+, or the
    # name itself without a hash.
    def hashed(name)
      return name unless digest

      bytes = OpenSSL::Digest.new(DIGESTS.fetch(digest)).digest(name)
      encoded = case hash_format
      when "base32" then DnsList.zbase32(bytes)
      when "base64" then [ bytes ].pack("m0")
      else bytes.unpack1("H*")
      end
      encoded = encoded.downcase unless hash_format == "base64"
      hash_len ? encoded[0, hash_len] : encoded
    end

    # z-base-32, taking each byte's low bits first.
    def self.zbase32(bytes)
      bits = bytes.bytes.each_with_index.sum { |byte, index| byte << (8 * index) }
      Array.new((bytes.bytesize * 8 + 4) / 5) { ZBASE32[(bits >> (5 * it)) & 0x1f] }.join
    end

    def takes?(address)
      address.ipv4? ? ipv4 : ipv6
    end

    def skips?(envelope)
      (exclude_users && !envelope.user.to_s.empty?) || (exclude_local && envelope.local?)
    end

    # The address delimiter for asking a whole address: @ for a hashed list.
    def delimiter
      emails_delimiter || (digest ? "@" : ".")
    end

    # What one answer fires: the returns it matches by code or by bit, else
    # the list's own symbol when there are no returns or +unknown+ is set,
    # each named for the checks that found the name.
    def fired(query, answer)
      number = IPAddr.new(answer).to_i rescue nil
      matched = returns.select { it.match?(answer, number) }

      fired = if matched.any?
        matched.map { [ it.symbol, it.weight, nil ] }
      elsif returns.empty?
        [ [ symbol, weight, nil ] ]
      elsif unknown
        [ [ symbol, weight, answer ] ]
      else
        []
      end

      fired.flat_map do |base, weight, unnamed|
        query.origins.map(&:last).uniq.map { |label| [ name_for(base, label), weight_for(weight, label), label ] }.uniq(&:first).map do |name, weight, label|
          detail = prefixes.empty? ? query.detail : query.detail(label)
          Fired.new(symbol: name, base:, weight:, query:, detail: [ detail, unnamed ].compact.join(" "))
        end
      end
    end

    # Whether +fired+ spares its origin the other lists.
    def allows?(fired)
      is_whitelist && returns.any? { it.symbol == fired.base } && !whitelist_exception.include?(fired.symbol)
    end

    def failure_symbol
      "#{symbol}_LOOKUP_FAILED"
    end

    # Each symbol the list may fire, with its weight and a description that
    # names the zone without its key.
    def symbols
      zone = shown_zone
      named = [ [ symbol, weight, "Listed in #{zone}" ], *returns.map { [ it.symbol, it.weight, "Listed in #{zone} as #{it.bit ? "bit #{it.bit}" : it.codes.join(", ")}" ] } ]
      labels = prefixes.empty? ? [ nil ] : prefixes.keys

      labels.flat_map do |label|
        named.map { |name, weight, description| [ name_for(name, label), [ weight_for(weight, label), description ] ] }
      end.to_h.merge(failure_symbol => [ 0.0, "Lookup in #{zone} failed" ])
    end

    def shown_zone
      zone.split(".").map { it.match?(KEY_LABEL) ? "<key>" : it }.join(".")
    end

    private
      def name_for(name, label)
        prefixes[label] ? "#{prefixes[label]}_#{name}" : name
      end

      def weight_for(weight, label)
        weight.is_a?(Hash) ? weight.fetch(prefixes.fetch(label)) : weight
      end
  end
end
