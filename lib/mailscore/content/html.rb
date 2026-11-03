module MailScore
  class Content
    # HTML read by regex alone: its visible text, its links with their text,
    # and its start tags. One pass over tokens, linear in the input.
    class Html
      TOKEN = /<[^<>]*>|[^<]+|</
      TAG = /\A<\s*(\/?)\s*([a-z][a-z0-9]*)/i
      ATTRIBUTE = /([^\s=\/"'<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/
      ENTITY = /&(?:#(\d{1,7})|#x(\h{1,6})|([a-z]{2,8}));/i
      ENTITIES = { "amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " " }.freeze
      HIDDEN = %w[ script style title ].freeze
      # Comments open outside these, as HTML5 reads them; inside, all is
      # text to their end tag.
      RAW_TEXT = %w[ script style title textarea ].freeze
      OPENING = /<!--|<(#{RAW_TEXT.join("|")})(?=[\s\/>])/i
      END_TAGS = RAW_TEXT.to_h { [ it, /<\/#{it}[\s\/>]/i ] }.freeze
      BREAKS = %w[ br p div tr td th li h1 h2 h3 h4 h5 h6 table ].freeze
      LINK_CAP = 1000

      Link = Data.define(:href, :text)

      Tag = Data.define(:name, :source) do
        def [](attribute)
          source.scan(ATTRIBUTE).find { |key, *| key.casecmp?(attribute) }&.then { |_, double, single, bare| Html.unescape(double || single || bare.to_s) }
        end
      end

      def self.unescape(string)
        string.gsub(ENTITY) do
          code = $1&.to_i || $2&.hex
          if code
            code <= 0x10FFFF && !(0xD800..0xDFFF).cover?(code) ? code.chr(Encoding::UTF_8) : "�"
          else
            ENTITIES.fetch($3.downcase, $&)
          end
        end
      end

      attr_reader :text, :links, :tags

      def initialize(source)
        @text = +""
        @links = []
        @tags = []
        read(without_comments(source))
        @text = @text.gsub(/\s+/, " ").strip
      end

      private
        def read(source)
          hidden = anchor = nil

          source.scan(TOKEN) do |token|
            match = token.match(TAG)
            closing, name = match&.captures
            name = name&.downcase

            if hidden
              hidden = nil if closing == "/" && name == hidden
            elsif name.nil?
              next if token.start_with?("<!", "<?")

              text = Html.unescape(token)
              @text << text
              anchor.last << text if anchor
            elsif closing == "/"
              anchor = link(anchor) if name == "a"
              @text << " " if BREAKS.include?(name)
            else
              tag = Tag.new(name:, source: match.post_match)
              @tags << tag
              hidden = name if HIDDEN.include?(name)
              @text << " " if BREAKS.include?(name)

              if name == "a"
                link(anchor)
                anchor = [ tag["href"], +"" ]
              end
            end
          end

          link(anchor)
        end

        # Records an open anchor and returns nil, the anchor closed.
        def link(anchor)
          href, text = anchor
          @links << Link.new(href: href.strip, text: text.gsub(/\s+/, " ").strip) if href && @links.size < LINK_CAP
          nil
        end

        # +source+ without its comments, in one pass. A raw text element is
        # kept whole, so a comment inside it hides nothing after it.
        def without_comments(source)
          kept = +""
          offset = 0

          while (start = source.byteindex(OPENING, offset))
            opening = $~
            kept << source.byteslice(offset...start)

            if (element = opening[1]&.downcase)
              offset = source.byteindex(END_TAGS.fetch(element), start) || source.bytesize
              kept << source.byteslice(start...offset)
            else
              offset = comment_end(source, start + 4)
            end
          end

          kept << source.byteslice(offset..).to_s
        end

        # Where a comment that opened just before +offset+ ends: at once for
        # <!--> and <!--->, after its -->, or, with no --> left in the
        # source, at the end of its tag.
        def comment_end(source, offset)
          if source.byteslice(offset, 1) == ">"
            offset + 1
          elsif source.byteslice(offset, 2) == "->"
            offset + 2
          elsif !@unclosed && (close = source.byteindex("-->", offset))
            close + 3
          else
            @unclosed = true
            (source.byteindex(">", offset) || source.bytesize - 1) + 1
          end
        end
    end
  end
end
