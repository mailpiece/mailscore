# mailscore

🛡️ A boring spam scorer for mail servers.

Score inbound mail over a small HTTP API. **mailscore** takes each message once after DATA and answers with one action by score, so your mail server just acts on it.

Use it anywhere you need to judge mail you receive yourself: scoring for a self-hosted MX, a filter beside an existing MTA, or scoring for an inbound-webhook pipeline.

**mailscore** handles:

- one scan per message after DATA, answered with an action by score
- greylisting, only for mail that scores high enough
- SPF, DKIM, DMARC, ARC, HELO and PTR, checked itself
- header, bounce and content checks, such as look-alike domains and risky attachments
- reputation for the client IP, its DKIM signers and its SPF record
- Bayes, fastText and fuzzy hashes, learned from your own mail
- traps and autolearn, off by default
- no third-party data by default: DNS lists only when configured

Plus:

- a Ruby client in its own gem, [mailscore-ruby](https://github.com/mailpiece/mailscore-ruby), with no dependencies
- rules as plain Ruby classes, with a time budget per scan
- one log line per scan, never message content



## Contents

- [Installation](#installation)
- [Getting Started](#getting-started)
- [Design](#design)
  - [Role: scoring only](#role-scoring-only)
  - [Processes, not threads](#processes-not-threads)
  - [Rules: plain classes](#rules-plain-classes)
- [Interfaces](#interfaces)
- [Testing](#testing)
- [History](#history)
- [Contributing](#contributing)
- [License](#license)



## Installation

```ruby
gem "mailscore", github: "mailpiece/mailscore"
```

Requires Ruby >= 3.4

That is the server. A Ruby caller needs only the client:

```ruby
gem "mailscore-ruby", github: "mailpiece/mailscore-ruby"
```

## Getting Started

Start the daemon with its tokens in ENV:

```sh
MAILSCORE_READ_TOKEN=... MAILSCORE_WRITE_TOKEN=... mailscore
```

Set one token or both; one alone serves both. Each should be at least 32 characters, such as `openssl rand -hex 32` makes. Nothing else is needed: it reads `/etc/mailscore.yml` if there is one, and every setting has a default. The database defaults to `/data/mailscore.sqlite3`, so outside the container point `database` at a directory that exists.

To change a setting, name a config file holding only what differs:

```yaml
database: tmp/mailscore.sqlite3
actions:
  reject: 12 # the other thresholds keep their defaults
```

```sh
MAILSCORE_READ_TOKEN=... MAILSCORE_WRITE_TOKEN=... mailscore mailscore.yml
```

Every setting, with its default, is in [docs/mailscore.example.yml](docs/mailscore.example.yml). An unknown or malformed setting, a config file named but missing, or a database that can't be opened stops it at boot.



## Design



### Role: scoring only

mailscore scores mail. Receiving, storing and delivering it are out of scope. Use your MTA, or mailsmtp, for those.

### Processes, not threads

fastText-ruby does not release the GVL and the rules hold it anyway, so mailscore runs Puma in cluster mode: scans run in parallel across worker processes. The workers share one SQLite database in WAL mode; each opens its own connection after the fork, and the first worker expires stale rows every minute by default. With fastText on, the first worker also checks every hour whether a day has passed since the last training and, once each class has enough samples, trains a new model in a forked child, so the training does not stall its scans.

### Rules: plain classes

A rule is a plain class under `MailScore::Rule`, built once per scan as `rule.new(config, database)`, with `NAME`, `GROUP`, `WEIGHT` and `DESCRIPTION` constants and a `run(message, envelope)` that returns nil or a `MailScore::Hit`. A rule with several symbols, such as the authentication rule, lists them in `SYMBOLS` and may return several hits. The message is parsed once per scan, with its Subject's MIME encoded words decoded to UTF-8, and rules scan at most 200 KB of its text, with text parts decoded to UTF-8 once, HTML read by regex and at most 100 URLs kept. `MailScore::Rules::ALL` lists them, `/check` runs them and `/symbols` reads it. A rule that raises counts as not fired. Every regexp runs under a global `Regexp.timeout`. The scanner reads the clock before each rule and skips the rest past the budget; a rule that does DNS caps its timeouts by `envelope.remaining`.

## Interfaces

- [HTTP API](docs/api.md): JSON over HTTP on a private network, with a read token and a write token. It also states what callers do with each action.
- [Deploy](docs/deploy.md): the container image, with Docker or as a Kamal accessory.

Ruby callers use the [mailscore-ruby](https://github.com/mailpiece/mailscore-ruby) gem, a Net::HTTP client for the HTTP API with no other dependencies.

## Testing

```sh
bundle install
rake
```



## History

View the [changelog](CHANGELOG.md).

## Contributing

Everyone is encouraged to help improve this project:

- [Report bugs](https://github.com/mailpiece/mailscore/issues)
- Fix bugs and submit pull requests
- Write, clarify, or fix documentation
- Suggest or add new features



## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
