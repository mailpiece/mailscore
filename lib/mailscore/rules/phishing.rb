module MailScore
  module Rules
    # A link whose text starts with an address on one domain while its href
    # goes to another. Text counts as an address when it is written as one,
    # with a scheme, "www." or a path, so a name such as "Example.com" does
    # not. A domain matches another with the same name under any suffix, and
    # a wrapper matches when it names the shown domain as its one target.
    class Phishing < Rule
      NAME = "LINK_TEXT_MISMATCH"
      GROUP = "phishing"
      WEIGHT = 4.0
      DESCRIPTION = "Link text names another site"

      TRAILING = /[.,;:!?'")\]}>]+\z/
      SHOWN = %r{\A((?:https?|ftp)://|www\.)?((?:[a-z0-9-]+\.)+[a-z]{2,24})([/:?#]\S*)?\z}i
      NESTING = 5

      def run(message, _envelope)
        message.content.links.each do |link|
          shown = shown_host(link.text) or next
          target = Content::Url.parse(link.href) or next
          next unless target.scheme.match?(/\A(?:https?|ftp)?\z/)

          unless same_name?(shown, target.host) || trusted?(target) || wrapped(target)&.then { same_name?(shown, it.host) }
            return Hit.new(name: NAME, weight: WEIGHT, detail: "#{shown} links to #{target.host}")
          end
        end

        nil
      end

      private
        # A link wrapper or shortener, which may lead anywhere.
        def trusted?(url)
          url.within?(@config.trusted_redirectors) || url.within?(@config.shorteners)
        end

        def shown_host(text)
          address = text[/\A\S+/].to_s.sub(TRAILING, "")
          prefix, host, path = address.match(SHOWN)&.captures
          host.downcase if host && (prefix || path)
        end

        # The same registered name, such as example.co.uk and example.com.
        def same_name?(host, other)
          name(host) == name(other)
        end

        def name(host)
          Content::Url.domain(host).split(".").first
        end

        # The one URL the href's query names, followed through nested
        # wrappers to the last, or nil when there is none or more than one.
        def wrapped(url)
          leaf = nil

          NESTING.times do
            targets = query_urls(leaf || url)
            return leaf if targets.empty?
            return unless targets.one?

            leaf = targets.first
          end

          nil
        end

        def query_urls(url)
          query = url.url[/\?([^#]*)/, 1].to_s

          query.split(/[&;]/).filter_map do |pair|
            value = Content.utf8(pair.sub(/\A[^=]*=/, "").b.tr("+", " ").gsub(/%(\h\h)/n) { $1.hex.chr }, "utf-8")
            Content::Url.parse(value) if value.match?(%r{\A(?:https?|ftp)://}i)
          end
        end
    end
  end
end
