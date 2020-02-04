#!/usr/bin/env ruby

require "pry"
require_relative "cache"

describe BuildkiteCacheCommand do
  let (:config_file) { "valid_config_1.yml" }
  let (:valid_args) { ["save-caches", "--anka-command=anka", "--s3-prefix=cache", "--s3-bucket=buildkite", "--config-file=fixtures/#{config_file}"] }
  let (:command) { BuildkiteCacheCommand.new }

  describe :opt_parse! do
    before :each do
      ARGV.replace valid_args
    end

    it "enforces options" do
      ARGV.replace []
      expect{ command.opt_parse! }.to raise_error(StandardError, /Missing required <command> argument/)
      ARGV.replace valid_args[0...1]
      expect{ command.opt_parse! }.to raise_error(StandardError, /Required argument --anka-command not provided/)
      ARGV.replace valid_args[0...2]
      expect{ command.opt_parse! }.to raise_error(StandardError, /Required argument --s3-prefix not provided/)
      ARGV.replace valid_args[0...3]
      expect{ command.opt_parse! }.to raise_error(StandardError, /Required argument --s3-bucket not provided/)
      ARGV.replace valid_args[0...4]
      expect{ command.opt_parse! }.to raise_error(StandardError, /Required argument --config-file not provided/)
      ARGV.replace valid_args[0...4] + ["--config-file=fixtures/missing_config.yml"]
      expect{ command.opt_parse! }.to raise_error(StandardError, /No such file or directory/)
      ARGV.replace valid_args[0...5]
      expect{ command.opt_parse! }.not_to raise_error
    end

    it "correctly invalidates invalid configs" do
      Dir.glob("fixtures/invalid_config*") do |config|
        ARGV[-1] = "--config-file=#{config}"
      end
      expect{ command.opt_parse! }.not_to raise_error
      expect{ command.validate_config! }.to raise_error StandardError
    end

    it "correctly validates valid configs" do
      Dir.glob("fixtures/valid_config*") do |config|
        ARGV[-1] = "--config-file=#{config}"
      end
      expect{ command.opt_parse! }.not_to raise_error
      expect{ command.validate_config! }.not_to raise_error
    end
  end

  describe :evaluate_cache_key do
    it "evaluates {{ .Branch }}" do
      ENV["BUILDKITE_BRANCH"] = "branch-name"
      expect(command.evaluate_cache_key("v1-cache-{{ .Branch }}")).to eq "v1-cache-branch-name"
    end

    it "evaluates {{ .Revision }}" do
      ENV["BUILDKITE_COMMIT"] = "d34db33f"
      expect(command.evaluate_cache_key("v1-cache-{{ .Revision }}")).to eq "v1-cache-d34db33f"
    end

    it "evaluates {{ checksum Gemfile.lock }}" do
      expect(command.evaluate_cache_key("v1-cache-{{ checksum Gemfile.lock }}")).to eq "v1-cache-9a6ff3173e36040138cc30806cafbe662ae7875d"
    end

    it "errors on missing checksum file" do
      expect{ command.evaluate_cache_key("v1-cache-{{ checksum missingno }}") }.to raise_error StandardError
    end

    it "evaluates multiple templates" do
      ENV["BUILDKITE_BRANCH"] = "branch-name"
      ENV["BUILDKITE_COMMIT"] = "d34db33f"
      expect(command.evaluate_cache_key("v1-cache-{{ .Branch }}-{{ .Revision }}")).to eq "v1-cache-branch-name-d34db33f"
    end
  end

  describe :run do
    before :each do
      ARGV.replace valid_args
      command.opt_parse!
    end

    it "runs save_cache" do
      expect(command).to receive(:save_cache).twice.and_return nil
      command.run
    end

    it "runs restore_cache" do
      expect(command).to receive(:restore_cache).twice.and_return nil
      command.instance_variable_set(:@command, "restore-caches")
      command.run
    end
  end

  describe :restore_cache do
    before :each do
      ARGV.replace valid_args
      command.opt_parse!
    end

    it "restores each cache in config" do
      expect(command).to receive(:aws_list_caches).twice.and_return ["pipeline/test-cache"]
      expect(command).to receive(:aws_download_cache).twice.and_return nil
      command.instance_variable_set(:@command, "restore-caches")
      command.instance_variable_set(:@anka, "echo")
      expect{ command.run }.to output(/tar -xzf \\\$CACHE_FILE/).to_stdout
    end

    it "saves each cache in config" do
      expect(command).to receive(:aws_upload_cache).twice.and_return nil
      command.instance_variable_set(:@command, "save-caches")
      command.instance_variable_set(:@anka, "echo")
      expect{ command.run }.to output(/tar -czf \\\$CACHE_FILE/).to_stdout
    end
  end
end
