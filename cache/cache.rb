#!/usr/bin/env ruby

require 'json'
require 'optparse'
require 'yaml'

class BuildkiteCacheCommand
  def opt_parse!
    OptionParser.new do |opts|
      opts.banner = "Usage: cache.rb [options] <command>"

      opts.on("--anka-command STRING", :REQUIRED, String, "The full anka run command") { |anka| @anka = anka }
      opts.on('--s3-prefix STRING', :REQUIRED, String, 'Prefix for cache S3 keys') { |prefix| @prefix = prefix }
      opts.on('--s3-bucket STRING', :REQUIRED, String, 'S3 Bucket to download and restore caches to') { |bucket| @bucket = bucket }
      opts.on('--config-file FILE', :REQUIRED, String, 'Yaml config for the cache plugin') { |file| @config = YAML.load(File.open(file).read) }
    end.parse!

    if ARGV.length < 1
      raise "Missing required <command> argument. Must be either restore-caches or save-caches."

    end

    if ARGV.length > 1
      raise "Received unexpected argument(s) #{ARGV[1..]}"
    end

    @command = ARGV[0]

    if !["restore-caches", "save-caches"].include? @command
      raise "Unknown command \"#{@command}\". Must be either restore-caches or save-caches."
    end

    if @anka.nil?
      raise "Required argument --anka-command not provided"
    end

    if @prefix.nil?
      raise "Required argument --s3-prefix not provided"
    end

    if @bucket.nil?
      raise "Required argument --s3-bucket not provided"
    end

    if @config.nil?
      raise "Required argument --config-file not provided"
    end
  end

  def run
    if @command == "restore-caches"
      @config.each do |cache|
        restore_cache(cache)
      end
      anka_extract_caches if Dir[".buildkite_restored_caches/*"].length > 0
    elsif @command == "save-caches"
      @config.each do |cache|
        cache_key = evaluate_cache_key(cache["keys"].first)
        if File.exists? ".buildkite_restored_caches/#{cache_key}.tar.gz"
          puts "Skipping cache upload, already downloaded"
          next
        end
        save_cache(cache)
      end
    end
  end

  def evaluate_cache_key(cache_key)
    # Find templated sections (e.g. {{ .Branch }})
    cache_key.gsub(/{{(.+?)}}/).each do
      # gsub sets $1 to first matching group
      contents = $1.strip
      if contents == ".Branch"
        ENV["BUILDKITE_BRANCH"].gsub('/','_')
      elsif contents == ".Revision"
        ENV["BUILDKITE_COMMIT"]
      elsif contents.split.first == "checksum" && contents.split.length > 1
        checksum = `set -o pipefail && cat #{contents[9..]} | shasum`.split.first
        if $?.exitstatus != 0
          raise "Checksum failed"
        end
        checksum
      else
        raise "Unknown templating command \"#{contents}\". Only {{ checksum <file> }}, {{ .Branch }}, and {{ .Revision }} are supported"
      end
    end
  end

  # Use aws cli instead of the gem to reduce dependencies
  def aws_list_caches(key)
    cmd = %{
      aws s3api list-objects \
        --bucket="#{@bucket}" \
        --prefix="#{@prefix}/#{key}" \
        --query 'sort_by(Contents,&LastModified)[].Key' 2> /dev/null \
      || echo []
    }
    JSON.load `#{cmd}`
  end

  def aws_upload_cache(cache_key)
    puts "Uploading cache #{cache_key}"
    `aws s3 cp .buildkite_saved_caches/#{cache_key}.tar.gz s3://#{@bucket}/#{@prefix}/`
  end

  def aws_download_cache(path)
    s3_key = "s3://#{@bucket}/#{path}"
    puts "Downloading cache #{s3_key}"
    `aws s3 cp #{s3_key} .buildkite_restored_caches/`
  end

  def anka_extract_caches
    cmd = %{#{@anka} bash -c "tar -C /Users/anka/app -xzf .buildkite_restored_caches/*.tar.gz"}
    puts "Extracting caches"
    `#{cmd}`
  end

  def anka_compress_cache(cache_key, paths)
    cmd = %{#{@anka} bash -c "mkdir .buildkite_saved_caches && tar -C /Users/anka/app -czf .buildkite_saved_caches/#{cache_key}.tar.gz #{paths}"}
    puts "Compressing #{cache_key}.tar.gz"
    `#{cmd}`
  end

  def validate_config!
    if @config.class != Array
      raise "Config must be an array of cache objects"
    end

    @config.each do |cache|
      unless cache.include?("keys")
        raise "Cache config must have \"keys\" key"
      end
      unless cache.include?("paths")
        raise "Cache config must have \"paths\" key"
      end
      if (cache["keys"].class != Array || cache["keys"].length == 0)
        raise "Cache must have at least one key in an array"
      end
      if (cache["paths"].class != Array || cache["paths"].length == 0)
        raise "Cache must have at least one path in an array"
      end
      if (cache.length != 2)
        raise "Cache must only have \"keys\" and \"paths\" keys"
      end
    end
  end

  def restore_cache(cache)
    selected_cache = nil
    cache["keys"].each do |key|
      key = evaluate_cache_key(key)
      caches = aws_list_caches(key)
      selected_cache = caches.last
      break unless selected_cache.nil?
    end

    if selected_cache.nil?
      puts "No caches to restore for #{cache["keys"].last}"
      return
    end

    aws_download_cache(selected_cache)
  end

  def save_cache(cache)
    paths = "'" + cache["paths"].join("' '") + "'"
    cache_key = evaluate_cache_key(cache["keys"].first)
    anka_compress_cache(cache_key, paths)
    aws_upload_cache(cache_key)
  end
end

if __FILE__==$0
  command = BuildkiteCacheCommand.new
  begin
    command.opt_parse!
    command.validate_config!
  rescue StandardError => e
    STDERR.puts e
    exit 1
  end

  command.run
end
