module MailScore
  module Rules
    # More than one sender address, in one From field or across several: a
    # reader may see one sender and a signature vouch for another.
    class MultipleFrom < Rule
      NAME = "FROM_MULTIPLE_ADDRESSES"
      WEIGHT = 8.0
      DESCRIPTION = "More than one address in From"

      def run(message, _envelope)
        addresses = message.from_addresses
        Hit.new(name: NAME, weight: WEIGHT, detail: addresses.join(", ")) if addresses.size > 1
      end
    end
  end
end
