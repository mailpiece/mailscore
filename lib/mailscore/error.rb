module MailScore
  # The root of what mailscore raises, so a caller can rescue its failures in
  # one place and leave its own bugs to surface.
  class Error < StandardError; end
end
