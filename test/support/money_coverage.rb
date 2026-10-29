require "json"
require "coverage"
require "fileutils"

module MoneyCoverage
  CORPORA = {
    full: "MoneyCoverageExercise.full",
    minimal: "MoneyCoverageExercise.minimal"
  }.freeze

  class << self
    def measure(paths, corpus: :full)
      raise ArgumentError, "unknown corpus #{corpus.inspect}" unless CORPORA.key?(corpus)

      tmp = Rails.root.join("tmp")
      FileUtils.mkdir_p(tmp)
      run_id = "#{Process.pid}-#{@runs = @runs.to_i + 1}"
      script = tmp.join("money_coverage_probe-#{run_id}.rb")
      report = tmp.join("money_coverage_report-#{run_id}.json")
      FileUtils.rm_f(report)

      File.write(script, probe_source(paths, corpus, report))
      pid = Process.spawn(clean_env, RbConfig.ruby, script.to_s, out: File::NULL, err: $stderr)
      Process.wait(pid)
      status = $?

      raise "the coverage probe exited with #{status.exitstatus} and wrote no report" unless status.success?
      raise "the coverage probe wrote no report" unless File.exist?(report)

      JSON.parse(File.read(report))
    ensure
      FileUtils.rm_f(script) if script
      FileUtils.rm_f(report) if report
    end

    private
      def clean_env
        {
          "RAILS_ENV" => "test",
          "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
          "BUNDLE_FROZEN" => "true",
          "COVERAGE" => "false"
        }
      end

      def probe_source(paths, corpus, report)
        <<~RUBY
          require "coverage"

          Coverage.start(lines: true, branches: true)


          Rails.application.eager_load!



          File.write(
          )
        RUBY
      end
  end

  class Report
    def initialize(paths)
      @paths = paths
    end

    def to_h
      result = Coverage.result

      {
        "files" => @paths.map { |path| relative(path) },
        "executable_lines" => executable_lines(result),
        "uncovered_lines" => uncovered_lines(result),
        "uncovered_branches" => uncovered_branches(result)
      }
    end

    private
      def relative(path)
        path.delete_prefix("#{Dir.pwd}/")
      end

      def entry_for(result, path)
        result[path] || result[File.realpath(path)] || {}
      end

      def executable_lines(result)
        @paths.sum { |path| entry_for(result, path).fetch(:lines, []).count { |count| !count.nil? } }
      end

      def uncovered_lines(result)
        @paths.flat_map do |path|
          entry_for(result, path).fetch(:lines, []).each_index.filter_map do |index|
            [ relative(path), index + 1 ] if entry_for(result, path).fetch(:lines, [])[index] == 0
          end
        end
      end

      def uncovered_branches(result)
        @paths.flat_map do |path|
          entry_for(result, path).fetch(:branches, {}).flat_map do |line, arms|
            arms.each_with_index.filter_map do |arm, index|
              [ relative(path), line, index ] if arm.nil?
            end
          end
        end
      end
  end
end
