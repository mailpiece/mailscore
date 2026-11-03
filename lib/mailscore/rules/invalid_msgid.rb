module MailScore
  module Rules
    # Message-ID fields none of which is left@right, angle brackets
    # optional, or carries a comment.
    class InvalidMsgid < Rule
      NAME = "MESSAGE_ID_INVALID"
      WEIGHT = 1.7
      DESCRIPTION = "Message-ID is malformed"

      MSGID = /\A<?[^<>\\ \t\r\n\v\u0080-\u{10ffff}]+@[^<>\\ \t\r\n\v\u0080-\u{10ffff}]+>?\s*\z/
      COMMENT = /\(.*\)/

      def run(message, _envelope)
        ids = message.header_values("message-id")
        Hit.new(name: NAME, weight: WEIGHT, detail: ids.first) unless ids.empty? || ids.any? { it.match?(MSGID) || it.match?(COMMENT) }
      end
    end
  end
end
