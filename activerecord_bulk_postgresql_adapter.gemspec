lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "activerecord_bulk_postgresql_adapter/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord_bulk_postgresql_adapter"
  spec.version = ActiverecordBulkPostgresqlAdapter::VERSION
  spec.authors = ["Hazumi Ichijo"]
  spec.email = ["hahihu314+github@gmail.com"]

  spec.summary = %q{T/ODO: Write a short summary, because RubyGems requires one.}
  spec.description = %q{T/ODO: Write a longer description or delete this line.}
  spec.homepage = "https://github.com/rerost"
  spec.license = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    # spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

    spec.metadata["homepage_uri"] = spec.homepage
    spec.metadata["source_code_uri"] = "http://github.com/rerost/activerecord_bulk_postgresql_adapter"
    # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
            "public gem pushes."
  end
  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", "~> 8.0.2"
  spec.add_dependency "pg", ">= 1.1"
  spec.add_development_dependency "bundler", "~> 2.6.9"
  spec.add_development_dependency "rake", "~> 13.3"
  spec.add_development_dependency "rspec", "~> 3.13.1"
end
