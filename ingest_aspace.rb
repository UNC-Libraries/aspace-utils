#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'bundler'
require 'date'
Bundler.require(:default)

raise "No config" unless File.exist?('config.yml')
$config = YAML.safe_load(IO.read('config.yml'))

class IngestLogger
  def initialize(path)
    @file = File.open(path, 'a')
    @lock = Mutex.new
  end

  %I|debug info warn error|.each do |level|
    define_method level, ->(text = nil, &block) do
      if block
        text = block.yield
      end

      @lock.synchronize do
        @file.write("#{DateTime.now.to_s.sub(/-04:00\z/, '')} [#{level.to_s.upcase}] #{text}\n")
        @file.flush
      end
    end
  end

  def close
    @file.close
  end
end

class ErrorResponseLogger
  @@start_marker = '<<<<<<<<<<<<<<<<<<<<<<<<<<<'
  @@end_marker   = '>>>>>>>>>>>>>>>>>>>>>>>>>>>'

  def initialize(path)
    @file = File.open(path, 'a')
    @lock = Mutex.new
  end

  def debug(phase, fname, object)
    is_error = object.is_a? StandardError
    @lock.synchronize do
      @file.puts "#{is_error ? "Error" : "Response"} for '#{fname}' at #{DateTime.now.to_s.sub(/-04:00\z/, '')} [#{phase.to_s.upcase}]"
      @file.puts @@start_marker
      @file.puts (is_error ? object.backtrace.join("\n") : object.body)
      @file.puts @@end_marker
      @file.flush
    end
  end

  def close
    @file.close
  end
end

$ingest_logger = IngestLogger.new('ingestlog.log')
$error_logger = ErrorResponseLogger.new('error_responses')

$ingest_logger.info { "Start of Processing" }

class AspaceIngester
  @@auth = nil

  def parse_json(txt)
    JSON.parse(txt)
  rescue JSON::ParserError => e
    nil
  end

  def initialize
    @hydra = Typhoeus::Hydra.new(max_concurrency: $config.fetch('max_concurrency', 4))
    @base_uri = "#{$config['backend_uri']}"
    # If `exclude_list.txt` exists, use it to create an array of EADs to be
    # excluded from ingest
    @exclude_list = read_exclude_list('exclude_list.txt')
  end

  def authorize
    res = Typhoeus.post(URI.join(@base_uri, "/users/#{$config.fetch('username', 'admin')}/login"),
                        params: {password: $config['password']})
    if res.code == 200
      sess = parse_json(res.body)
      token = sess['session']
      return (@@auth = token) if token
    end

    $ingest_logger.error { "Failed to aquire auth" }
    raise "Failed to aquire auth"
  end

  # Read list of EADs to exclude from ingest
  #
  # Returns an array of file basename strings to be excluded from ingest.
  # Returns an empty array if passed filepath is not present.
  #
  # File should contain a newline-delimited list of filenames without filepaths
  # or extensions. (e.g. '12345'; NOT '12345.xml' or '/eads/12345'). Refer to
  # exclude_list.txt.example for an example file.
  def read_exclude_list(filepath)
    return [] unless File.file?(filepath)

    exclude_list = []
    File.foreach(filepath) do |line|
      next if line.start_with?('#')

      line.chomp!
      exclude_list << line unless line.empty?
    end

    exclude_list
  end

  def skip_file?(fname)
    basename = File.basename(fname, '.xml')
    @exclude_list.include?(basename)
  end

  def queue_for_ingest(fname)
    repo_id = $config.fetch('repository_id', 2)
    $totlock.synchronize do
      $total += 1
    end

    # Skip EADs on the exclude list
    if skip_file?(fname)
      $excludelock.synchronize do
        $excludes += 1
      end
      $ingest_logger.info { "Conversion of '#{fname}' skipped per exclude list" }
      return
    end

    json_req = Typhoeus::Request.new(
      URI.join(@base_uri, "/repositories/#{repo_id}/jsonmodel_from_format/resource/#{$config.fetch('converter_method', 'ead')}"),
      method: :post,
      accept_encoding: "gzip",
      headers: {
        'X-ArchivesSpace-Session' => @@auth,
        'Content-Type' => 'text/xml; charset=UTF-8'
      },
      body: IO.read(fname)
    )
    json_req.on_complete do |res|
      success = if res.code != 200
               $ingest_logger.warn { "Conversion of '#{fname}' failed with code '#{res.code}', body of response is in 'error_responses'" }
               $error_logger.debug(:conversion, fname, res)
               nil
             elsif (payload = parse_json(res.body)) && payload.is_a?(Hash)
               $ingest_logger.warn { "Conversion of '#{fname}' failed with error '#{payload['error']}'" }
               nil
             else
               $ingest_logger.info { "Conversion of '#{fname}' succeeded" }
               payload
             end
      if success
        upload_req = Typhoeus::Request.new(
          URI.join(@base_uri, "/repositories/#{repo_id}/batch_imports"),
          method: :post,
          accept_encoding: "gzip",
          headers: {
            'X-ArchivesSpace-Session' => @@auth,
            'Content-type' => 'application/json; charset=UTF-8'
          },
          body: success.to_json)
        upload_req.on_complete do |res|
          if res.code != 200
            $ingest_logger.warn { "Upload of '#{fname}' failed with code '#{res.code}', body of response is in 'error_responses'" }
            $error_logger.debug(:upload, fname, res)
            nil
          elsif (payload = parse_json(res.body)) &&
                payload.last.key?('errors') &&
                !payload.last['errors'].empty?
            $ingest_logger.warn { "Upload of '#{fname}' failed with error '#{payload.last['errors']}'" }
            nil
          else
            $ingest_logger.info { "Upload of '#{fname}' succeeded"}
            $succlock.synchronize do
              $successes += 1
            end
            payload
          end
        end
        @hydra.queue(upload_req)
      end
    end
    @hydra.queue(json_req)
  end

  def run
    @hydra.run
  end
end

$successes = 0
$excludes = 0
$total = 0

$succlock = Mutex.new
$excludelock = Mutex.new
$totlock = Mutex.new

$ingest_logger.info { "BEGIN INGEST" }
client = AspaceIngester.new

ingest_files = Dir[File.join($config['ingest_dir'], '*.xml')].sort
ingest_files.each_slice($config.fetch('batch_size', 20)) do |batch|
  client.authorize
  if batch.count > 0
    batch.each do |fname|
      client.queue_for_ingest(fname)
    end
    client.run
  end
end

$ingest_logger.info { "OK: #{$successes} EXCLUDED: #{$excludes} FAIL: #{$total - $successes - $excludes} TOTAL: #{$total}" }
$ingest_logger.info { "END INGEST" }

$ingest_logger.close
$error_logger.close
