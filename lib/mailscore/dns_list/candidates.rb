require "ipaddr"
require "mailauth"
require "public_suffix"
require "simpleidn"

module MailScore
  class DnsList
    # What one message offers the lists, read once per scan: for a list,
    # each origin with the check that found it and the name to ask for it.
    class Candidates
      MESSAGE_ID_DOMAIN = /@([^.]+\.[^>]+)/
      CHECKS = { "emails" => :email, "urls" => :url, "content_urls" => :url }.freeze

      def initialize(message, envelope, resolver)
        @message = message
        @envelope = envelope
        @resolver = resolver
      end

      # An international name is asked in its xn-- form, and one too long
      # for the DNS is not asked.
      def for(list)
        list.checks.map { CHECKS.fetch(it, it.to_sym) }.uniq.flat_map { send(it, list) }
          .map { |origin, label, name, address| [ origin, label, address ? name : ascii(name), address ] }.reject { |_, _, name| name.nil? }.uniq
      end

      private
        # The client IP, by its octets or nibbles reversed.
        def from(list)
          address = @envelope.address
          address && list.takes?(address) ? [ [ address.to_s, "from", DnsList.reversed(address), true ] ] : []
        end

        # The addresses the top +received_max_pos+ Received headers name,
        # the hops nearest this server, at most +requests_limit+, reversed
        # likewise: not one in the local networks for a list that says
        # +exclude_local+, nor the client's own when the list asks about it
        # by +from+ too. The sender writes every header further down.
        def received(list)
          @message.header_values("received").first([ list.received_max_pos, list.requests_limit ].min).filter_map { Received.address(it) }.uniq.filter_map do |address|
            next if !list.takes?(address) || (list.exclude_local && @envelope.local_networks.any? { it.include?(address) })
            next if address == @envelope.address && list.checks.include?("from")

            [ address.to_s, "received", DnsList.reversed(address), true ]
          end
        end

        def helo(_list)
          helo = @envelope.helo&.downcase&.delete_suffix(".")
          helo ? [ [ helo, "helo", helo ] ] : []
        end

        # The client's host name, the caller's or the one looked up.
        def rdns(_list)
          hostname = @envelope.client_hostname(@resolver)&.downcase&.delete_suffix(".")
          hostname && hostname != "unknown" ? [ [ hostname, "rdns", hostname ] ] : []
        end

        # The domains of the DKIM signatures that verify, or their
        # registrable domains when the list says +dkim_domainonly+.
        def dkim(list)
          dkim_domains.map do |domain|
            name = list.dkim_domainonly && !list.url_full_hostname ? registrable(domain) || domain : domain
            [ name, "dkim", name ]
          end
        end

        # Addresses in the text and mailto links, at most +requests_limit+,
        # and one per registrable domain when asked by domain.
        def email(list)
          emails = @message.content.emails.map { Address.new(it) }
          emails = emails.uniq { registrable(it.domain) || it.domain } if list.emails_domainonly
          emails.first(list.requests_limit).filter_map do |email|
            domain = list.url_full_hostname ? email.domain : registrable(email.domain) || email.domain
            address(list, email, "email", domain:)
          end
        end

        def replyto(list)
          reply_to = @message.header("reply-to").to_s[/[^<\s,"]+@[^>\s,"]+/]
          reply_to ? [ address(list, Address.new(reply_to.downcase), "replyto") ].compact : []
        end

        # The first URL of each registrable domain, in the text, shown links
        # first, and then the Subject, at most +requests_limit+, past which
        # TOO_MANY_LINKS: its registrable domain, or its whole host with
        # +url_full_hostname+, or its address reversed unless the list says
        # +no_ip+.
        def url(list)
          urls = [ *@message.content.urls, *@message.subject.to_s.scan(Content::Url::PATTERN).filter_map { Content::Url.parse(it) } ]
          urls = urls.reject(&:ip?) if list.no_ip
          urls = urls.filter_map { |url| (url.ip? ? url.host : registrable(url.host))&.then { [ url, it ] } }.uniq(&:last)
          @message.limits << "TOO_MANY_LINKS" if urls.size > list.requests_limit

          urls.first(list.requests_limit).filter_map do |url, domain|
            if url.ip?
              address = IPAddr.new(url.host.delete("[]")) rescue nil
              [ url.host, "url", DnsList.reversed(address), true ] if address
            else
              name = list.url_full_hostname ? url.host : domain
              [ name, "url", name ]
            end
          end
        end

        def from_smtp(list)
          sender = @envelope.mail_from.to_s.downcase
          sender.include?("@") ? [ selected(list, sender, "from_smtp") ] : []
        end

        def from_mime(list)
          sender = @message.from_addresses.first.to_s.downcase
          sender.include?("@") ? [ selected(list, sender, "from_mime") ] : []
        end

        def mid(_list)
          domain = @message.header("message-id").to_s.scan(MESSAGE_ID_DOMAIN).flatten.last&.downcase
          domain ? [ [ domain, "mid", domain ] ] : []
        end

        # The domain alone when the list says +emails_domainonly+, else the
        # whole address.
        def selected(list, address, label)
          value = list.emails_domainonly ? address.rpartition("@").last : address
          [ value, label, value ]
        end

        # An address with its tags and Gmail's dots taken out: its domain when
        # the list says +emails_domainonly+, else user.domain, or user@domain
        # for a hashed list.
        def address(list, email, label, domain: email.domain)
          return if email.user.empty? || email.domain.empty?

          if list.emails_domainonly
            [ domain, label, domain ]
          else
            [ email.to_s, label, "#{email.user}#{list.delimiter}#{email.domain}" ]
          end
        end

        # The registrable domain by the public suffix list, nil for a suffix
        # itself or a name with none.
        def registrable(host)
          PublicSuffix.domain(host)
        end

        # Converting takes time that grows with the square of a label's
        # length, so a name the DNS could not take anyway, past 253 bytes or
        # with a label past 63 characters, is nil before it is converted.
        def ascii(name)
          return name if name.ascii_only?
          return if name.bytesize > 253 || name.split(".").any? { it.size > 63 }

          SimpleIDN.to_ascii(name)
        rescue StandardError
          name
        end

        def dkim_domains
          return [] if @envelope.trusted?

          dkim = @envelope.lookups.fetch(:dkim) { @envelope.lookups[:dkim] = MailAuth::Dkim.verify(MailAuth::Message.new(@message.raw), resolver: @resolver) }
          Rules::Authentication.credited(dkim).passing_domains.map(&:downcase).uniq
        end

        # The address a Received header says the hop came from: the one in its
        # first comment, as in "from mx.example.com (mx.example.com
        # [192.0.2.1])", else the one after from.
        module Received
          def self.address(value)
            from = value.gsub(/\s+/, " ").strip[/\Afrom\s+(.*)/i, 1] or return
            data = from[/\A[^\s(]*/]
            comment = from[/\A[^\s(]*\s*\(([^()]*)\)/, 1]
            tcp_info(comment) || tcp_info(data)
          end

          def self.tcp_info(text)
            return if text.to_s.empty?

            opening, closing = text.index("["), text.rindex("]")
            if text.start_with?("[")
              parse(text[1...text.index("]")]) if closing
            else
              (parse(text) if text.match?(/\A\h/)) || (parse(text[opening + 1...closing]) if opening && closing && closing > opening)
            end
          end

          def self.parse(text)
            IPAddr.new(text.sub(/\AIPv6:/i, "")).native
          rescue IPAddr::Error
            nil
          end
        end

        # An email address with its +tags taken out, and Gmail's dots.
        class Address
          GMAIL = %w[ gmail.com googlemail.com ].freeze

          attr_reader :user, :domain

          def initialize(address)
            user, _, domain = address.rpartition("@")
            user = user.delete(".") if GMAIL.include?(domain)
            @user = user.match?(/\A[^+]+\+/) ? user[/\A[^+]+/] : user
            @domain = domain == "googlemail.com" ? "gmail.com" : domain
          end

          def to_s
            "#{user}@#{domain}"
          end
        end
    end
  end
end
