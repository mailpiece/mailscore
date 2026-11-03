require "mailscore/content/html"
require "mailscore/content/url"

module MailScore
  # A message's text parts decoded once per scan, from base64 or
  # quoted-printable and their charset to UTF-8, scrubbed and capped at
  # TEXT_CAP in all; its HTML read by regex, its URLs and its attachments.
  class Content
    TEXT_CAP = Message::TEXT_CAP
    ARCHIVE_CAP = 10 * 1024 * 1024
    # A zip's entry names: each cut to the last NAME_BYTES, where its file
    # name and extension are, ENTRY_CAP and NAMES_BYTES of them per archive,
    # and MESSAGE_ENTRY_CAP per message. Past any, TOO_MANY_ZIP_ENTRIES.
    NAME_BYTES = 255
    ENTRY_CAP = 1000
    NAMES_BYTES = 64 * 1024
    MESSAGE_ENTRY_CAP = 5000
    TEXT_TYPES = %w[ text/plain text/html ].freeze
    PARAMETER = /;\s*([^\s=;*]+)(\*\d+)?(\*)?\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^\s;]+))/
    ENCODED_WORD = /=\?([^?\s]+)\?([bq])\?([^?\s]*)\?=/i
    ZIP_ENTRIES = [ [ "PK\x03\x04".b, 26, 30 ], [ "PK\x01\x02".b, 28, 46 ] ].freeze
    EMAIL = /\b[a-z0-9._%+-]+@(?:[a-z0-9-]+\.)+[a-z]{2,}\b/i

    TextPart = Data.define(:type, :text, :encoding)

    # The entry names a message's zips may still have read.
    Entries = Struct.new(:left)

    class Attachment
      attr_reader :name, :type, :part

      def initialize(name:, type:, part:, entries: Entries.new(MESSAGE_ENTRY_CAP))
        @name, @type, @part, @entries = name, type, part, entries
      end

      def extension
        Content.extension(name)
      end

      # Entry names of a zip, read from its headers without unpacking it.
      def archive_names
        @archive_names ||= if !zip?
          []
        elsif @entries.left.zero?
          part.limits << "TOO_MANY_ZIP_ENTRIES"
          []
        else
          Content.zip_entries(Content.decode(part, ARCHIVE_CAP), cap: [ ENTRY_CAP, @entries.left ].min, limits: part.limits).tap { @entries.left -= it.size }
        end
      end

      private
        def zip?
          extension == "zip" || %w[ application/zip application/x-zip-compressed ].include?(type)
        end
    end

    def self.decode(part, cap)
      raw = part.body.byteslice(0, cap * 3)

      bytes = case transfer_encoding(part)
      when "base64" then raw.unpack1("m")
      when "quoted-printable" then raw.unpack1("M")
      else raw
      end

      bytes.byteslice(0, cap)
    end

    # The last extension, lowercased, ignoring the trailing dots and spaces
    # that Windows drops.
    def self.extension(name)
      split_name(name).last
    end

    # The file name, without its folders, lowercased and trimmed as for
    # +extension+, as the stem before its last extension and that extension.
    # A name that starts with its only dot has none, as a dotfile.
    def self.split_name(name)
      base = name.to_s.downcase.reverse.sub(/\A[\s.]+/, "").reverse.split(%r{[/\\]}).last.to_s
      stem, dot, extension = base.rpartition(".")
      dot.empty? || stem.empty? ? [ base, "" ] : [ stem, extension ]
    end

    # A file name without the control characters, such as NUL, that no file
    # system keeps.
    def self.file_name(name)
      name.delete("\u0000-\u001f\u007f")
    end

    def self.transfer_encoding(part)
      part.header("content-transfer-encoding").to_s.strip.downcase
    end

    def self.utf8(bytes, charset)
      encoding = Message::ENCODINGS.fetch(charset.to_s.downcase, Encoding::UTF_8)
      bytes = bytes.dup.force_encoding(encoding)
      encoding == Encoding::UTF_8 ? bytes.scrub : bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue EncodingError
      bytes.force_encoding(Encoding::UTF_8).scrub
    end

    # The distinct names in a zip's local headers and then its central
    # directory, up to +cap+, where each entry has one of each. The scan
    # goes on past where a name ends, so none is read from inside another,
    # and a name that runs past the bytes is not read.
    def self.zip_entries(bytes, cap: ENTRY_CAP, limits: Set.new)
      names = Set.new
      headers = size = 0

      ZIP_ENTRIES.each do |signature, length_at, name_at|
        offset = 0

        while (offset = bytes.index(signature, offset))
          length = bytes.byteslice(offset + length_at, 2)&.unpack1("v")
          start = offset + name_at
          next offset += signature.bytesize if length.nil? || start + length > bytes.bytesize

          kept = [ length, NAME_BYTES ].min
          name = file_name(utf8(bytes.byteslice(start + length - kept, kept), "utf-8"))
          if (headers += 1) > cap * 2 || (!names.include?(name) && (names.size == cap || (size += kept) > NAMES_BYTES))
            limits << "TOO_MANY_ZIP_ENTRIES"
            return names.to_a
          end

          names << name
          offset = start + length
        end
      end

      names.to_a
    end

    attr_reader :text_parts, :attachments

    def initialize(message)
      @limits = message.limits
      leaves = [ message, *message.parts ].reject { it.content_type.start_with?("multipart/") }
      @entries = Entries.new(MESSAGE_ENTRY_CAP)
      @attachments = leaves.filter_map { attachment(it) }
      @text_parts = text_parts_of(leaves - @attachments.map(&:part))
    end

    def plain
      @plain ||= text_parts.select { it.type == "text/plain" }.map(&:text).join("\n")
    end

    def html
      @html ||= text_parts.select { it.type == "text/html" }.map { Html.new(it.text) }
    end

    def links
      @links ||= html.flat_map(&:links)
    end

    # Each distinct URL, up to Url::CAP: in the hrefs of the links a reader
    # sees, by their text, then in the text, then in the links without any,
    # with the first of each domain before every second, so a message cannot
    # pad its URLs to push one out. Past the cap, TOO_MANY_LINKS.
    def urls
      @urls ||= begin
        shown, hidden = links.partition { !it.text.empty? }
        found = [ *shown.map(&:href), *plain.scan(Url::PATTERN), *html.flat_map { it.text.scan(Url::PATTERN) }, *hidden.map(&:href) ]
          .filter_map { Url.parse(it) }.uniq(&:url)
        @limits << "TOO_MANY_LINKS" if found.size > Url::CAP

        firsts = found.uniq(&:domain)
        (firsts + (found - firsts)).first(Url::CAP)
      end
    end

    # Each distinct email address in mailto links and the text, lowercased,
    # up to Url::CAP.
    def emails
      @emails ||= [ *links.filter_map { it.href[/\Amailto:([^?]+)/i, 1] }, *plain.scan(EMAIL), *html.flat_map { it.text.scan(EMAIL) } ]
        .map { it.strip.downcase }.select { it.match?(/\A#{EMAIL}\z/) }.uniq.first(Url::CAP)
    end

    # The text a reader sees: the plain parts, or the HTML's text without them.
    def visible_text
      @visible_text ||= visible_parts.join("\n")
    end

    # The same text, one entry per part.
    def visible_parts
      @visible_parts ||= plain.strip.empty? ? html.map(&:text) : text_parts.select { it.type == "text/plain" }.map(&:text)
    end

    # Each visible part's language as +detector+ names it, once per scan.
    def visible_languages(detector)
      (@visible_languages ||= {})[detector] ||= visible_parts.map { detector.detect(it) }
    end

    private
      def text_parts_of(parts)
        budget = TEXT_CAP

        parts.filter_map do |part|
          next unless TEXT_TYPES.include?(part.content_type) && budget > 0

          bytes = Content.decode(part, budget)
          budget -= bytes.bytesize
          TextPart.new(type: part.content_type, text: Content.utf8(bytes, part.content_type_param("charset")), encoding: Content.transfer_encoding(part))
        end
      end

      # A named part is an attachment, except a text part shown inline.
      def attachment(part)
        disposition = part.header("content-disposition").to_s.strip.downcase
        name = (parameter(part.header("content-disposition"), "filename") || parameter(part.header("content-type"), "name"))&.then { Content.file_name(it) }
        inline_text = TEXT_TYPES.include?(part.content_type) && disposition.start_with?("inline")

        if disposition.start_with?("attachment") || (name && !inline_text)
          Attachment.new(name:, type: part.content_type, part:, entries: @entries)
        end
      end

      # A parameter's value, with RFC 2231 continuations and encoded words.
      def parameter(value, name)
        pieces = value.to_s.scan(PARAMETER).select { |key, *| key.casecmp?(name) }
        return if pieces.empty?

        pieces.sort_by { |_, index, *| index.to_s.delete("*").to_i }.map do |_, _, extended, quoted, bare|
          piece = (quoted&.gsub(/\\(.)/, '\1') || bare).b
          extended ? piece.sub(/\A[^']*'[^']*'/n, "").gsub(/%(\h\h)/n) { $1.hex.chr } : piece
        end.join.then { decode_words(Content.utf8(it, "utf-8")) }
      end

      def decode_words(value)
        value.gsub(ENCODED_WORD) do
          charset, encoding, text = $1, $2.downcase, $3
          Content.utf8(encoding == "b" ? text.unpack1("m") : text.tr("_", " ").unpack1("M"), charset)
        end
      end
  end
end
