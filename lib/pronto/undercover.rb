# frozen_string_literal: true

require 'pronto'
require 'undercover/options'
require 'undercover'
require 'pronto/patch_changeset'
require 'json'

module Pronto
  # Runner class for undercover
  class Undercover < Runner
    DEFAULT_LEVEL = :warning

    def initialize(patches, _commit = nil)
      super
      @patch_changeset = Pronto::PatchChangeset.new(patches)
    end

    # @return Array[Pronto::Message]
    def run
      return [] if !@patches || @patches.count.zero?

      overall_coverage_message = Message.new(nil, nil, :info, total_coverage_message, nil, self.class)
      patch_messages = @patches
        .select { |patch| valid_patch?(patch) }
        .map { |patch| patch_to_undercover_message(patch) }
        .flatten.compact

      [overall_coverage_message, patch_messages]
    rescue Errno::ENOENT => e
      warn("Could not open file! #{e}")
      []
    end

    private

    def valid_patch?(patch)
      patch.additions.positive? && ruby_file?(patch.new_file_full_path)
    end

    def total_coverage_message
      base_json = JSON.parse(File.read('coverage/.last_base_run.json'))
      head_json = JSON.parse(File.read('coverage/.last_run.json'))
      base_covered_percent = base_json['result']['covered_percent']
      head_covered_percent = head_json['result']['covered_percent']
      diff = head_covered_percent - base_covered_percent

      [
        "base branch: **#{base_covered_percent.round(2)}%**",
        "head branch: **#{head_covered_percent.round(2)}%**",
        "diff: **#{diff.round(2)}%**"
      ].join(', ')
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def patch_to_undercover_message(patch)
      offending_line_numbers(patch).map do |warning, msg_line_no|
        patch
          .added_lines
          .select { |line| line.new_lineno == msg_line_no }
          .map do |line|
            lines = untested_lines_for(warning)
            path = line.patch.delta.new_file[:path]
            msg = "#{warning.node.human_name} #{warning.node.name} missing tests" \
                  " for line#{'s' if lines.size > 1} #{lines.join(', ')}" \
                  " (coverage: #{warning.coverage_f})"
            Message.new(path, line, DEFAULT_LEVEL, msg, nil, self.class)
          end
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def undercover_warnings
      @undercover_warnings ||= ::Undercover::Report.new(
        @patch_changeset, undercover_options
      ).build.flagged_results
    end

    def offending_line_numbers(patch)
      patch_lines = patch.added_lines.map(&:new_lineno)
      path = patch.new_file_full_path.to_s
      undercover_warnings
        .select { |warning| File.expand_path(warning.file_path) == path }
        .map do |warning|
          first_line_no = patch_lines.find { |l| warning.uncovered?(l) }
          [warning, first_line_no] if first_line_no
        end.compact
    end

    def untested_lines_for(warning)
      warning.coverage.map do |ln, _cov|
        ln if warning.uncovered?(ln)
      end.compact
    end

    # rubocop:disable Metrics/AbcSize
    def undercover_options
      config = Pronto::ConfigFile.new.to_h['pronto-undercover']
      return ::Undercover::Options.new.parse([]) unless config

      opts = []
      opts << "-l#{config['lcov']}" if config['lcov']
      opts << "-r#{config['ruby-syntax']}" if config['ruby-syntax']
      opts << "-p#{config['path']}" if config['path']
      ::Undercover::Options.new.parse(opts)
    end
    # rubocop:enable Metrics/AbcSize
  end
end
