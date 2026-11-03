require "digest"
require "mittens"

module MailScore
  class Bayes
    # A message's tokens: a few header tokens, the registrable domains of its
    # first URL_CAP distinct URL domains, then orthogonal sparse bigrams over
    # the words of its Subject and of each part of its decoded text. With a
    # WINDOW of 2 they pair each word with the next, at distance 1. Each token
    # appears once, hashed to a signed 64-bit integer, and at most CAP are kept.
    #
    # A +detector+, whose +detect+ names a text's language and which calls
    # every text English by default, gives each part its language. Its words
    # are stemmed for it when Snowball has a stemmer for it, and the
    # Subject's for the first part's; then a stop word of any language goes,
    # whatever the part's language, so a bigram pairs the words either side
    # of one.
    module Tokens
      WINDOW = 2
      CAP = 2000
      URL_CAP = 5

      # A word as Unicode's default word boundaries find one: letters, marks,
      # digits and underscores, with invisible format characters inside, and
      # joined across an apostrophe, a period or a middle dot between letters
      # or an apostrophe, period, comma or semicolon between digits; or a
      # currency sign on its own.
      WORD = /[\p{L}\p{N}\p{Pc}][\p{L}\p{M}\p{N}\p{Pc}\p{Cf}]*(?:(?:(?<=\p{L})['’.·](?=\p{L})|(?<=\p{N})['’.,;](?=\p{N}))[\p{L}\p{M}\p{N}\p{Pc}\p{Cf}]+)*|\p{Sc}/
      KEPT = /[\p{L}\p{M}\p{N}\p{Pc}\p{Sm}\p{Sc}]/

      STEMMERS = Hash.new do |stemmers, language|
        stemmers[language] = begin
          Mittens::Stemmer.new(language:)
        rescue ArgumentError
        end
      end

      # Snowball's stop words, each stemmed for its own language, in one set
      # for every language.
      STOP_WORDS = Dir[File.join(__dir__, "stop_words", "*.txt")].flat_map do |path|
        stemmer = STEMMERS[File.basename(path, ".txt")]
        File.readlines(path, chomp: true).map { stemmer.stem(it) }
      end.to_set.freeze

      def self.of(message, detector = Language::DEFAULT)
        parts = parts(message, detector)

        headers(message).each.chain(urls(message), bigrams("subject", message.subject, parts.dig(0, 1)),
          *parts.map { |text, language| bigrams("text", text, language) })
          .lazy.uniq.first(CAP).map { Digest::SHA256.digest(it).unpack1("q>") }
      end

      # Each word in NFKC and lowercase, keeping only its letters, marks,
      # digits, underscores and math and currency signs, so "don't" reads
      # "dont". With a +language+, each is stemmed when there is a stemmer for
      # it, and a stop word of any language goes.
      def self.words(text, language = nil)
        words = text.to_s.scan(WORD).map { it.unicode_normalize(:nfkc).downcase.scan(KEPT).join }.reject(&:empty?)
        return words unless language

        stemmer = STEMMERS[language]
        words.map { stemmer ? stemmer.stem(it) : it }.reject { STOP_WORDS.include?(it) }
      end

      # Each part of the text with its language.
      def self.parts(message, detector)
        message.content.visible_parts.zip(message.content.visible_languages(detector))
      end

      def self.headers(message)
        mailer = message.header("x-mailer") || message.header("user-agent")

        { "from" => message.from_addresses.first.to_s.split("@").last,
          "message-id" => message.header("message-id").to_s[/@([^>\s]+)/, 1],
          "mailer" => mailer.to_s[/\A[^\s\/]*/],
          "content-type" => message.content_type }.map { |name, value| "header\0#{name}\0#{value.to_s.downcase}" }
      end

      # An IP host stands for itself.
      def self.urls(message)
        message.content.urls.map { it.ip? ? it.host : it.domain }.uniq.first(URL_CAP).map { "url\0#{it}" }
      end

      def self.bigrams(kind, text, language = nil)
        words = words(text, language)

        Enumerator.new do |tokens|
          words.each_with_index do |word, index|
            (1...WINDOW).each do |distance|
              break unless (other = words[index + distance])
              tokens << "#{kind}\0#{distance}\0#{word}\0#{other}"
            end
          end
        end
      end
    end
  end
end
