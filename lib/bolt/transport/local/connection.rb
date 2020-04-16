# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'tempfile'
require 'bolt/node/output'
require 'bolt/util'

module Bolt
  module Transport
    class Local < Simple
      class Connection
        attr_accessor :user, :logger, :target

        def initialize(target)
          @target = target
          # The familiar problem: Etc.getlogin is broken on osx
          @user = ENV['USER'] || Etc.getlogin
          @logger = Logging.logger[self]
        end

        def shell
          @shell ||= if Bolt::Util.windows?
                       Bolt::Shell::Powershell.new(target, self)
                     else
                       Bolt::Shell::Bash.new(target, self)
                     end
        end

        def copy_file(source, dest)
          @logger.debug { "Uploading #{source}, to #{dest}" }
          if source.is_a?(StringIO)
            Tempfile.create(File.basename(dest)) do |f|
              f.write(source.read)
              FileUtils.mv(t, dest)
            end
          else
            # Mimic the behavior of `cp --remove-destination`
            # since the flag isn't supported on MacOS
            FileUtils.cp_r(source, dest, remove_destination: true)
          end
        rescue StandardError => e
          message = "Could not copy file to #{dest}: #{e}"
          raise Bolt::Node::FileError.new(message, 'COPY_ERROR')
        end

        def execute(command)
          if Bolt::Util.windows?
            command += "\r\nif (!$?) { if($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } }"
            script_file = Tempfile.new(['wrapper', '.ps1'], target.options['tmpdir'])
            File.write(script_file, command)
            script_file.close

            command = ['powershell.exe', *Bolt::Shell::Powershell::PS_ARGS, script_file.path]
          end

          Open3.popen3(*command)
        end

        # This is used by the Bash shell to decide whether to `cd` before
        # executing commands as a run-as user
        def reset_cwd?
          false
        end
      end
    end
  end
end