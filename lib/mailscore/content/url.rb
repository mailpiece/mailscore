require "homographic_spoofing"

module MailScore
  class Content
    # A URL found in a message, with its host lowercased and percent-decoded.
    Url = Data.define(:url, :scheme, :host)

    class Url
      PATTERN = %r{\b(?:https?://|www\.)[^\s<>"'`]+}i
      AUTHORITY = %r{\A(?:([a-z][a-z0-9+.-]*):)?//(?:[^/?#@\\]*@)?(\[[^\]/]*\]|[^/?#:\\@\[\]<>^|\x00-\x20\x7f]*)}i
      TRAILING = /\A[.,;:!?'")\]}>]+/
      IP = /\A(?:(?:0x\h{1,8}|\d{1,10})(?:\.(?:0x\h{1,8}|\d{1,10})){0,3}|\[[\h:.]+\])\z/i
      SECOND_LEVELS = %w[ co com net org gov edu ac ne or go ].freeze
      CAP = 1000

      def self.parse(string)
        string = string.strip.reverse.sub(TRAILING, "").reverse
        string = "http://#{string}" if string.match?(/\Awww\./i)
        scheme, host = string.match(AUTHORITY)&.captures
        host = Content.utf8(host.b.gsub(/%(\h\h)/n) { $1.hex.chr }, "utf-8").downcase.delete_suffix(".") if host

        new(url: string, scheme: scheme.to_s.downcase, host:) unless host.to_s.empty?
      end

      # The registrable domain, guessed without a public suffix list.
      def self.domain(host)
        labels = host.split(".")
        size = labels.size > 2 && labels[-1].size == 2 && SECOND_LEVELS.include?(labels[-2]) ? 3 : 2
        labels.last(size).join(".")
      end

      # A host spelled to pass for another, by Chrome's IDN policy.
      def self.homograph?(host)
        HomographicSpoofing.idn_spoof?(host)
      end

      def ip?
        host.match?(IP)
      end

      def domain
        Url.domain(host)
      end

      def homograph?
        Url.homograph?(host)
      end

      # Whether the host is one of +domains+ or below one.
      def within?(domains)
        domains.any? { host == it || host.end_with?(".#{it}") }
      end
    end
  end
end
