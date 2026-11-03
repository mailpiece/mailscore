require "digest"

module MailScore
  # Fuzzy hashes, one store for all mail, each under a flag such as spam.
  #
  # A text part is normalized: lowercased, URLs without their query string or
  # fragment, whitespace collapsed. With at least +fuzzy_min_words+ words, it
  # is stored under the SHA-256 of that text, with 32 min-hashes of its word
  # 3-grams. A shorter one is stored under the SHA-256 of that text and the
  # Subject once their bytes times TEXT_MULTIPLIER reach
  # +fuzzy_min_attachment_size+. An attachment of an application type, and an
  # image at least MIN_IMAGE_SIDE pixels wide and high, of at least
  # +fuzzy_min_attachment_size+ bytes each, is stored under the SHA-256 of its
  # decoded body. Logos and other small images are not hashed.
  #
  # A part matches a stored one by its exact hash, at similarity 1.0, or by the
  # share of min-hashes they have in common, above +fuzzy_threshold+: more than
  # 16 of 32 by default.
  #
  # A message gives at most PART_CAP distinct hashes, and they are looked
  # up and deleted CHUNK at a time, well within SQLite's bound on variables.
  class Fuzzy
    PART_CAP = 100
    CHUNK = 500
    # Each seed's SHA-512 of a 3-gram gives eight 64-bit words, so four seeds
    # give the 32 min-hashes.
    SEEDS = %w[ mailscore-fuzzy-0 mailscore-fuzzy-1 mailscore-fuzzy-2 mailscore-fuzzy-3 ].freeze
    MINHASHES = 32
    TEXT_MULTIPLIER = 4
    MIN_IMAGE_SIDE = 500
    JPEG_FRAMES = ([ *0xC0..0xCF ] - [ 0xC4, 0xC8, 0xCC ]).freeze

    Part = Data.define(:digest, :shingles)
    Match = Data.define(:flag, :count, :similarity)

    # An entry past its expiry that the sweep has not deleted yet starts over.
    ADD = <<~SQL
      INSERT INTO fuzzy_hashes (hash, flag, count, last_seen, expires_at) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (hash, flag) DO UPDATE SET
        count = iif(expires_at <= excluded.last_seen, excluded.count, count + excluded.count),
        last_seen = excluded.last_seen,
        expires_at = excluded.expires_at
    SQL

    def self.words(text)
      text.gsub(Content::Url::PATTERN) { it.sub(/[?#].*/m, "") }.downcase.split
    end

    # One integer per seed word: its index in the top 5 bits, so a lookup
    # matches index to index, and its minimum in the 58 below.
    def self.shingles(words)
      digests = words.each_cons(3).map { it.join(" ") }.uniq.map do |gram|
        SEEDS.flat_map { |seed| Digest::SHA512.digest("#{seed}\0#{gram}").unpack("Q>8") }
      end

      digests.transpose.each_with_index.map { |values, index| (index << 58) | (values.min >> 6) }
    end

    # A PNG, GIF or JPEG's width and height, read from its header, or nil.
    def self.dimensions(image)
      if image.start_with?("\x89PNG\r\n\x1A\n".b)
        image.byteslice(16, 8)&.unpack("NN")
      elsif image.start_with?("GIF87a", "GIF89a")
        image.byteslice(6, 4)&.unpack("vv")
      elsif image.start_with?("\xFF\xD8".b)
        jpeg_dimensions(image)
      end&.then { it if it.size == 2 && it.all? }
    end

    # Walks the JPEG markers to the first frame header, which holds the size.
    def self.jpeg_dimensions(image)
      offset = 2

      while (marker, type, length = image.byteslice(offset, 4)&.unpack("CCn")) && marker == 0xFF && length
        return image.byteslice(offset + 5, 4)&.unpack("nn")&.reverse if JPEG_FRAMES.include?(type)
        offset += 2 + length
      end
    end

    def initialize(config, database)
      @config = config
      @database = database
      @stats = Stats.new(database)
    end

    def parts(message)
      parts = (text_parts(message) + binary_parts(message)).uniq(&:digest)
      MailScore.logger.warn "fuzzy read #{PART_CAP} of #{parts.size} parts" if parts.size > PART_CAP
      parts.first(PART_CAP)
    end

    # Adds the message's hashes under +flag+, +count+ to each, and returns how
    # many it has.
    def add(message, flag, count: 1, now: Time.now)
      parts = parts(message)
      expires_at = (now.to_i + @config.fuzzy_expiry).ceil

      @database.transaction do
        parts.each do |part|
          @database.execute(ADD, part.digest, flag, count, now.to_i, expires_at)
          next if part.shingles.empty?

          rows = ([ "(?, ?, ?, ?)" ] * part.shingles.size).join(", ")
          @database.execute(<<~SQL, *part.shingles.flat_map { [ part.digest, flag, it, expires_at ] })
            INSERT INTO fuzzy_shingles (hash, flag, shingle, expires_at) VALUES #{rows}
            ON CONFLICT DO UPDATE SET expires_at = excluded.expires_at
          SQL
        end
      end

      @stats.increment("fuzzy_adds")
      parts.size
    end

    # Deletes the message's own hashes under +flag+ and returns how many it
    # has, as +add+ does, whether or not they were stored.
    def delete(message, flag)
      hashes = parts(message).map(&:digest)
      return 0 if hashes.empty?

      @database.transaction do
        hashes.each_slice(CHUNK) do |chunk|
          @database.execute("DELETE FROM fuzzy_shingles WHERE flag = ? AND hash IN (#{marks(chunk)})", flag, *chunk)
          @database.execute("DELETE FROM fuzzy_hashes WHERE flag = ? AND hash IN (#{marks(chunk)})", flag, *chunk)
        end
      end

      @stats.increment("fuzzy_deletes")
      hashes.size
    end

    # The best match per configured flag, most similar first.
    def check(message, now: Time.now)
      parts = parts(message)
      candidates = exact(parts, now.to_i) + parts.flat_map { similar(it, now.to_i) }

      matches = candidates.select { |match| @config.fuzzy_flags.key?(match.flag) && (match.similarity == 1.0 || match.similarity > @config.fuzzy_threshold) }
        .group_by(&:flag).map { |_, found| found.max_by { [ it.similarity, it.count ] } }
        .sort_by { -it.similarity }

      matches.each { @stats.increment("fuzzy_matches") }
      matches
    end

    private
      def text_parts(message)
        content = message.content
        texts = content.text_parts.select { it.type == "text/plain" }.map(&:text) + content.html.map(&:text)
        subject = message.subject.to_s

        texts.filter_map do |text|
          words = Fuzzy.words(text)
          text = words.join(" ")

          if words.size >= @config.fuzzy_min_words
            Part.new(digest: Digest::SHA256.hexdigest(text), shingles: Fuzzy.shingles(words))
          elsif words.any? && (text.bytesize + subject.bytesize) * TEXT_MULTIPLIER >= @config.fuzzy_min_attachment_size
            Part.new(digest: Digest::SHA256.hexdigest("#{text}\0#{subject}"), shingles: [])
          end
        end
      end

      # Attachments of an application type, and images inline or attached.
      def binary_parts(message)
        attachments = message.content.attachments.select { it.type.start_with?("application/") }.map(&:part)
        images = [ message, *message.parts ].select { it.content_type.start_with?("image/") }

        (attachments | images).filter_map do |part|
          body = Content.decode(part, part.body.bytesize)
          next if body.bytesize < @config.fuzzy_min_attachment_size
          next if part.content_type.start_with?("image/") && !large_image?(body)

          Part.new(digest: Digest::SHA256.hexdigest(body), shingles: [])
        end
      end

      def large_image?(image)
        Fuzzy.dimensions(image)&.all? { it >= MIN_IMAGE_SIDE }
      end

      def exact(parts, now)
        parts.map(&:digest).each_slice(CHUNK).flat_map do |hashes|
          @database.execute("SELECT flag, count FROM fuzzy_hashes WHERE hash IN (#{marks(hashes)}) AND expires_at > ?", *hashes, now)
            .map { |flag, count| Match.new(flag:, count:, similarity: 1.0) }
        end
      end

      def similar(part, now)
        return [] if part.shingles.empty?

        @database.execute(<<~SQL, *part.shingles, now).map { |flag, count, shared| Match.new(flag:, count:, similarity: (shared.to_f / MINHASHES).round(2)) }
          SELECT fuzzy_shingles.flag, fuzzy_hashes.count, count(*) FROM fuzzy_shingles
          JOIN fuzzy_hashes USING (hash, flag)
          WHERE fuzzy_shingles.shingle IN (#{marks(part.shingles)}) AND fuzzy_hashes.expires_at > ?
          GROUP BY fuzzy_shingles.hash, fuzzy_shingles.flag
        SQL
      end

      def marks(values)
        ([ "?" ] * values.size).join(", ")
      end
  end
end
