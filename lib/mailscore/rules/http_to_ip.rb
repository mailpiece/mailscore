module MailScore
  module Rules
    # A URL whose host is a bare IP address.
    class HttpToIp < Rule
      NAME = "LINK_TO_IP_ADDRESS"
      WEIGHT = 1.0
      DESCRIPTION = "A link to a bare IP address"

      def run(message, _envelope)
        if (url = message.content.urls.find(&:ip?))
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host)
        end
      end
    end
  end
end
