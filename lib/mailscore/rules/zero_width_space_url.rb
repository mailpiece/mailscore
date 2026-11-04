module MailScore
  module Rules
    # A URL with a zero-width character in it, to slip past filters.
    class ZeroWidthSpaceUrl < Rule
      NAME = "LINK_ZERO_WIDTH_CHARACTER"
      GROUP = "url"
      WEIGHT = 7.0
      DESCRIPTION = "Hidden character in a link"

      ZERO_WIDTH = /[​-‍⁠﻿]/

      def run(message, _envelope)
        if (url = message.content.urls.find { it.url.match?(ZERO_WIDTH) })
          Hit.new(name: NAME, weight: WEIGHT, detail: url.host.gsub(ZERO_WIDTH, ""))
        end
      end
    end
  end
end
