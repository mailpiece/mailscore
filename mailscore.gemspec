require_relative "lib/mailscore/version"

Gem::Specification.new do |spec|
  spec.name = "mailscore"
  spec.version = MailScore::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.required_ruby_version = ">= 3.4"
  spec.authors = [ "Simon Lev" ]

  spec.summary = "A boring spam scorer for mail servers."
  spec.description = "Score inbound mail over a small HTTP API: one scan per message after DATA, one action by score, and learning from explicit reports."

  spec.homepage = "https://github.com/mailpiece/mailscore"
  spec.license = "MIT"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.txt",
    "exe/*",
    "docs/**/*.md",
    "CHANGELOG.md",
    "README.md",
    "LICENSE",
    "NOTICE",
    "mailscore.gemspec"
  ]
  spec.bindir = "exe"
  spec.executables = [ "mailscore" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "fasttext"
  spec.add_dependency "homographic_spoofing", "~> 0.2"
  spec.add_dependency "logger"
  spec.add_dependency "mailauth"
  spec.add_dependency "mailresolver"
  spec.add_dependency "maxmind-db"
  spec.add_dependency "mittens"
  spec.add_dependency "public_suffix"
  spec.add_dependency "puma"
  spec.add_dependency "rack"
  spec.add_dependency "simpleidn"
  spec.add_dependency "sqlite3"
end
