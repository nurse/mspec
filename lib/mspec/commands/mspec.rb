#!/usr/bin/env ruby

require 'mspec/version'
require 'mspec/utils/options'
require 'mspec/utils/script'
require 'mspec/helpers/tmp'
require 'mspec/runner/actions/filter'
require 'mspec/runner/actions/timer'


class MSpecMain < MSpecScript
  def initialize
    config[:includes] = []
    config[:requires] = []
    config[:target]   = ENV['RUBY'] || 'ruby'
    config[:flags]    = []
    config[:command]  = nil
    config[:options]  = []
    config[:launch]   = []
  end

  def options(argv=ARGV)
    config[:command] = argv.shift if ["ci", "run", "tag"].include?(argv[0])

    options = MSpecOptions.new "mspec [COMMAND] [options] (FILE|DIRECTORY|GLOB)+", 30, config

    options.doc " The mspec command sets up and invokes the sub-commands"
    options.doc " (see below) to enable, for instance, running the specs"
    options.doc " with different implementations like ruby, jruby, rbx, etc.\n"

    options.configure do |f|
      load f
      config[:options] << '-B' << f
    end

    options.targets

    options.on("--warnings", "Don't supress warnings") do
      config[:flags] << '-w'
      ENV['OUTPUT_WARNINGS'] = '1'
    end

    options.on("-j", "--multi", "Run multiple (possibly parallel) subprocesses") do
      config[:multi] = true
      config[:options] << "-fy"
    end

    options.version MSpec::VERSION do
      if config[:command]
        config[:options] << "-v"
      else
        puts "#{File.basename $0} #{MSpec::VERSION}"
        exit
      end
    end

    options.help do
      if config[:command]
        config[:options] << "-h"
      else
        puts options
        exit 1
      end
    end

    options.doc "\n Custom options"
    custom_options options

    # The rest of the help output
    options.doc "\n where COMMAND is one of:\n"
    options.doc "   run - Run the specified specs (default)"
    options.doc "   ci  - Run the known good specs"
    options.doc "   tag - Add or remove tags\n"
    options.doc " mspec COMMAND -h for more options\n"
    options.doc "   example: $ mspec run -h\n"

    options.on_extra { |o| config[:options] << o }
    options.parse(argv)

    if config[:multi]
      options = MSpecOptions.new "mspec", 30, config
      options.all
      patterns = options.parse(config[:options])
      @files = files_from_patterns(patterns)
    end
  end

  def register; end

  def multi_exec(argv)
    MSpec.register_files @files

    require 'mspec/runner/formatters/multi'
    formatter = MultiFormatter.new

    output_files = []
    children = cores.times.map { |i|
      name = tmp "mspec-multi-#{i}"
      output_files << name

      env = {
        "SPEC_TEMP_DIR" => "rubyspec_temp_#{i}",
        "MSPEC_MULTI" => i.to_s
      }
      command = argv + ["-o", name]
      $stderr.puts "$ #{command.join(' ')}" if $MSPEC_DEBUG
      IO.popen([env, *command], "rb+")
    }

    puts children.map { |child| child.gets("").chomp }.uniq
    formatter.start

    until @files.empty?
      IO.select(children)[0].each { |io|
        reply = io.read(1)
        case reply
        when '.'
          formatter.unload
        when nil
          raise "Worker died!"
        else
          while chunk = (io.read_nonblock(4096) rescue nil)
            reply += chunk
          end
          raise reply
        end
        io.puts @files.shift unless @files.empty?
      }
    end

    children.each { |child|
      child.puts "QUIT"
      Process.wait(child.pid)
    }

    formatter.aggregate_results(output_files)
    formatter.finish
  end

  def run
    argv = config[:target].split(/\s+/)

    argv.concat config[:launch]
    argv.concat config[:flags]
    argv.concat config[:includes]
    argv.concat config[:requires]
    if config[:multi]
      argv << "-r#{MSPEC_HOME}/lib/mspec/utils/empty_line.rb"
    end
    argv << "-v"
    argv << "#{MSPEC_HOME}/bin/mspec-#{ config[:command] || "run" }"
    argv.concat config[:options]

    if config[:multi]
      multi_exec argv
    else
      $stderr.puts "$ #{argv.join(' ')}"
      exec *argv
    end
  end
end
