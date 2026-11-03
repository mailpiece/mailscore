module MailScore
  module Rules
    # One link, through a URL shortener, and hardly any text.
    class RedirectorUrlOnly < Rule
      NAME = "SHORTENED_LINK_ONLY"
      WEIGHT = 1.0
      DESCRIPTION = "One shortened link and very little text"

      SHORTENERS = %w[ 1url.com adf.ly amzn.to bit.do bit.ly clck.ru cli.gs dlvr.it fb.me goo.gl is.gd lnkd.in ow.ly su.pr t.co tiny.cc tinyurl.com tr.im wp.me ].freeze

      def run(message, _envelope)
        if (url = UrlOnly.url(message.content)) && url.within?(SHORTENERS)
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host)
        end
      end
    end
  end
end
