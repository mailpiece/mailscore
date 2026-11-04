module MailScore
  module Rules
    # One link, through a URL shortener, and hardly any text.
    class RedirectorUrlOnly < Rule
      NAME = "SHORTENED_LINK_ONLY"
      GROUP = "url"
      WEIGHT = 1.0
      DESCRIPTION = "The message is only a shortened link"

      def run(message, _envelope)
        if (url = UrlOnly.url(message.content)) && url.within?(@config.shorteners)
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host)
        end
      end
    end
  end
end
