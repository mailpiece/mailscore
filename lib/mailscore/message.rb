module MailScore
  # A received message, split once into headers, body and MIME parts. +raw+
  # and +body+ stay binary; header values and +text+ are UTF-8, scrubbed.
  # Its first HEADER_CAP fields are read, within HEADER_BYTES, and indexed
  # by name once; the rest are dropped from +raw+ too. Its first PART_CAP
  # MIME parts are read, depth first, while their bodies come to PART_BYTES
  # in all, nested ones counted again at each level. A part is sliced once
  # from its parent's body, already in CRLF. +limits+ names each cap the
  # message reached, for the whole tree of parts.
  class Message
    HEADER_SEPARATOR = "\r\n\r\n".b
    HEADER_CAP = 1000
    HEADER_BYTES = 1024 * 1024
    PART_CAP = 1000
    PART_BYTES = 64 * 1024 * 1024
    TEXT_CAP = 200 * 1024
    MAX_DEPTH = 10
    ENCODED_WORD = /=\?([^?\s*]+)(?:\*[^?\s]*)?\?([BQ])\?([^?\s]*)\?=/i
    ENCODED_WORD_BYTES = 45
    # Each encoding by its names in lowercase, looked up as a charset
    # without raising, but none of Ruby's own settings.
    ENCODINGS = (Encoding.name_list - %w[ external filesystem internal locale ]).to_h { [ it.downcase, Encoding.find(it) ] }.freeze

    # What the message and all its parts share: the caps reached, and the
    # bytes of the parts sliced so far.
    Tree = Struct.new(:limits, :bytes)

    attr_reader :raw, :headers, :body

    def initialize(raw, depth: 0, tree: Tree.new(Set.new, 0))
      @raw = depth.zero? ? raw.to_s.b.gsub(/\r?\n/n, "\r\n") : raw
      headers, @body = @raw.start_with?("\r\n") ? [ "", @raw.byteslice(2..) ] : @raw.split(HEADER_SEPARATOR, 2)
      @body = @body.to_s
      @depth = depth
      @tree = tree
      @headers = utf8(capped(headers.to_s))
    end

    # The first field named +name+, unfolded, or nil.
    def header(name)
      header_values(name).first
    end

    def header_values(name)
      index.fetch(name.downcase, [])
    end

    # The Subject with its MIME encoded words (RFC 2047) decoded, or nil.
    def subject
      @subject ||= header("subject")&.then { self.class.decode_words(it) }
    end

    # +text+ with its encoded words decoded to UTF-8, scrubbed. Whitespace
    # between two encoded words goes; a word in an unknown charset stays.
    def self.decode_words(text)
      text.gsub(/#{ENCODED_WORD}(?:[ \t]+(?=#{ENCODED_WORD}))?/o) { decode_word($1, $2, $3) || $& }.scrub
    end

    # +text+ as a header value: as it is in printable ASCII, else as UTF-8
    # encoded words of at most 75 characters.
    def self.encode_words(text)
      return text if text.match?(/\A[\x20-\x7e]*\z/)

      text.each_char.slice_before(&chunker).map { "=?UTF-8?B?#{[ it.join ].pack("m0")}?=" }.join(" ")
    end

    def self.decode_word(charset, encoding, text)
      charset = ENCODINGS[charset.downcase] or return
      bytes = encoding.casecmp?("B") ? text.unpack1("m") : text.b.tr("_", " ").gsub(/=(\h\h)/n) { $1.hex.chr }
      bytes.force_encoding(charset).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue ArgumentError, EncodingError
      nil
    end

    def self.chunker
      bytes = 0
      ->(char) { (bytes += char.bytesize) > ENCODED_WORD_BYTES ? (bytes = char.bytesize) : false }
    end
    private_class_method :decode_word, :chunker

    def limits
      @tree.limits
    end

    def from_addresses
      addresses("from")
    end

    def to_addresses
      addresses("to")
    end

    # Lowercase type/subtype, text/plain when absent.
    def content_type
      type = header("content-type").to_s.split(";", 2).first.to_s.strip.downcase
      type.empty? ? "text/plain" : type
    end

    def content_type_param(name)
      params = header("content-type").to_s.scan(/;\s*([^\s=;]+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^\s;]+))/)
      params.find { |key, _, _| key.casecmp?(name) }&.then { |_, quoted, bare| quoted || bare }
    end

    # Every MIME part below this one, depth first, without descending into
    # message/rfc822, up to PART_CAP.
    def parts
      @parts ||= descendants(PART_CAP)
    end

    # The body that rules scan, capped at TEXT_CAP bytes.
    def text
      @text ||= utf8(body.byteslice(0, TEXT_CAP))
    end

    # The decoded text parts, HTML and attachments, read once per scan.
    def content
      @content ||= Content.new(self)
    end

    protected
      # Up to +cap+ parts below this one; past it, TOO_MANY_PARTS.
      def descendants(cap)
        children(cap + 1).each_with_object([]) do |child, found|
          if found.size == cap
            limits << "TOO_MANY_PARTS"
            break found
          end

          found << child
          found.concat(child.descendants(cap - found.size))
        end
      end

    private
      # Each field's unfolded values by its lowercase name.
      def index
        @index ||= fields.each_with_object({}) do |field, index|
          name, value = field.split(":", 2)
          (index[name.strip.downcase] ||= []) << value.gsub(/\r\n(?=[ \t])/, "").strip if value
        end.each_value(&:freeze)
      end

      def fields
        @fields ||= headers.each_line.each_with_object([]) do |line, fields|
          if fields.any? && line.start_with?(" ", "\t")
            fields.last << line
          else
            fields << line.dup
          end
        end
      end

      # The header block cut to whole lines within HEADER_BYTES, then before
      # its field past HEADER_CAP. A block cut short leaves +raw+ as the
      # fields kept and the body.
      def capped(block)
        kept = block.bytesize > HEADER_BYTES ? block.byteslice(0, HEADER_BYTES).then { it.byteslice(0, it.rindex("\r\n").to_i) } : block
        fields = 0
        size = 0
        kept.each_line do |line|
          break if !line.start_with?(" ", "\t") && (fields += 1) > HEADER_CAP
          size += line.bytesize
        end
        return block if size == block.bytesize

        limits << "TOO_MANY_HEADERS"
        block.byteslice(0, size).delete_suffix("\r\n").tap { @raw = "#{it}#{HEADER_SEPARATOR}#{body}".b }
      end

      def addresses(name)
        header_values(name).flat_map do |value|
          value.gsub(/"(?:\\.|[^"\\])*"/, " ").gsub(/\((?:\\.|[^()\\])*\)/, " ").scan(/[^\s<>,;:"()]+@[^\s<>,;:"()]+/)
        end
      end

      # The first +cap+ parts. A delimiter line is --boundary alone, with --
      # after it for the last and optional whitespace (RFC 2046), so a
      # boundary that begins an inner one never splits its parts.
      def children(cap)
        boundary = content_type_param("boundary") if content_type.start_with?("multipart/")
        return [] unless boundary&.ascii_only? && @depth < MAX_DEPTH

        delimiters = delimiters(/^--#{Regexp.escape(boundary)}(--)?[ \t]*(?:\r\n|\z)/n, cap + 1)
        delimiters.first(cap).each_with_index.each_with_object([]) do |(delimiter, index), parts|
          start = delimiter.end(0)
          finish = delimiters[index + 1]&.begin(0) || body.bytesize
          finish -= 2 if finish - start >= 2 && body.byteslice(finish - 2, 2) == "\r\n"
          break parts if delimiter[1] || !within_part_bytes?(finish - start)

          parts << Message.new(body.byteslice(start...finish), depth: @depth + 1, tree: @tree)
        end
      end

      def within_part_bytes?(size)
        @tree.bytes += size
        return true if @tree.bytes <= PART_BYTES

        limits << "TOO_MANY_PARTS"
        false
      end

      def delimiters(pattern, cap)
        found = []
        while found.size < cap && (match = pattern.match(body, found.last&.end(0) || 0))
          found << match
        end
        found
      end

      def utf8(string)
        string.dup.force_encoding(Encoding::UTF_8).scrub
      end
  end
end
