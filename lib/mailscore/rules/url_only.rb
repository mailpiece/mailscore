module MailScore
  module Rules
    # One link and hardly any text around it.
    class UrlOnly < Rule
      NAME = "LINK_ONLY"
      WEIGHT = 2.2
      DESCRIPTION = "One link and very little text"

      WORDS = 8
      WORD = /[\p{L}\p{N}]+/

      # The one URL, when there is little else.
      def self.url(content)
        urls = content.urls
        return unless urls.one?

        text = content.visible_text.gsub(Content::Url::PATTERN, " ")
        urls.first if text.enum_for(:scan, WORD).first(WORDS).size < WORDS
      end

      def run(message, _envelope)
        if (url = UrlOnly.url(message.content))
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host)
        end
      end
    end
  end
end
