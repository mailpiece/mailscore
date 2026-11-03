# Trains the fastText model once, in a process of its own. The server runs
# it with the settings it needs as JSON; the tokens come from ENV.
require "json"
require "mailscore"

begin
  config = MailScore::Config.parse(JSON.parse(ARGV.fetch(0)))
  MailScore.logger.level = config.log_level
  database = MailScore::Database.new(config.database, busy_timeout: config.database_busy_timeout)
  MailScore::Classifier::Trainer.new(config, database).train
rescue StandardError => error
  MailScore.logger.error "training failed: #{error.class}"
  exit 1
end
