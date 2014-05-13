# Copyright, 2014, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'rainbow'

module Process
	class Daemon
		# Daemon startup timeout
		TIMEOUT = 5

		# This module contains functionality related to starting and stopping the @daemon, and code for processing command line input.
		class Controller
			def initialize(daemon)
				@daemon = daemon
			end
			
			# This function is called from the daemon executable. It processes ARGV and checks whether the user is asking for `start`, `stop`, `restart`, `status`.
			def daemonize(argv = ARGV)
				case argv.shift.to_sym
				when :start
					start
					status
				when :stop
					stop
					status
					ProcessFile.cleanup(@daemon)
				when :restart
					stop
					ProcessFile.cleanup(@daemon)
					start
					status
				when :status
					status
				else
					raise ArgumentError.new("Invalid command. Please specify start, restart, stop or status.")
				end
			end
			
			# Launch the @daemon directly:
			def spawn
				@daemon.prefork
				@daemon.mark_log

				fork do
					Process.setsid
					exit if fork

					ProcessFile.store(@daemon, Process.pid)

					File.umask 0000
					Dir.chdir @daemon.working_directory

					$stdin.reopen "/dev/null"
					$stdout.reopen @daemon.log_file_path, "a"
					$stdout.sync = true
				
					$stderr.reopen $stdout
					$stderr.sync = true

					begin
						@daemon.run
					rescue Exception => error
						$stderr.puts "=== Daemon Exception Backtrace @ #{Time.now.to_s} ==="
						$stderr.puts "#{error.class}: #{error.message}"
						$!.backtrace.each { |at| $stderr.puts at }
						$stderr.puts "=== Daemon Crashed ==="
						$stderr.flush
					ensure
						$stderr.puts "=== Daemon Stopping @ #{Time.now.to_s} ==="
						$stderr.flush
					end
				end
			end

			# This function starts the supplied @daemon
			def start
				$stderr.puts Rainbow("Starting daemon...").blue

				case ProcessFile.status(@daemon)
				when :running
					$stderr.puts Rainbow("Daemon already running!").blue
					return
				when :stopped
					# We are good to go...
				else
					$stderr.puts Rainbow("Daemon in unknown state! Will clear previous state and continue.").red
					ProcessFile.clear(@daemon)
				end

				spawn

				sleep 0.1
				timer = TIMEOUT
				pid = ProcessFile.recall(@daemon)

				while pid == nil and timer > 0
					# Wait a moment for the forking to finish...
					$stderr.puts Rainbow("Waiting for daemon to start (#{timer}/#{TIMEOUT})").blue
					sleep 1

					# If the @daemon has crashed, it is never going to start...
					break if @daemon.crashed?

					pid = ProcessFile.recall(@daemon)

					timer -= 1
				end
			end
			
			# Prints out the status of the @daemon
			def status
				case ProcessFile.status(@daemon)
				when :running
					puts Rainbow("Daemon status: running pid=#{ProcessFile.recall(@daemon)}").green
				when :unknown
					if @daemon.crashed?
						puts Rainbow("Daemon status: crashed").red

						$stdout.flush
						$stderr.puts Rainbow("Dumping daemon crash log:").red
						@daemon.tail_log($stderr)
					else
						puts Rainbow("Daemon status: unknown").red
					end
				when :stopped
					puts Rainbow("Daemon status: stopped").blue
				end
			end

			# Stops the @daemon process.
			def stop
				$stderr.puts Rainbow("Stopping daemon...").blue

				# Check if the pid file exists...
				unless File.file?(@daemon.process_file_path)
					$stderr.puts Rainbow("Pid file not found. Is the daemon running?").red
					return
				end

				pid = ProcessFile.recall(@daemon)

				# Check if the @daemon is already stopped...
				unless ProcessFile.running(@daemon)
					$stderr.puts Rainbow("Pid #{pid} is not running. Has daemon crashed?").red

					@daemon.tail_log($stderr)

					return
				end

				# Interrupt the process group:
				pgid = -Process.getpgid(pid)
				Process.kill("INT", pgid)
				sleep 0.1

				sleep 1 if ProcessFile.running(@daemon)

				# Kill/Term loop - if the @daemon didn't die easily, shoot
				# it a few more times.
				attempts = 5
				while ProcessFile.running(@daemon) and attempts > 0
					sig = (attempts >= 2) ? "KILL" : "TERM"

					$stderr.puts Rainbow("Sending #{sig} to process group #{pgid}...").red
					Process.kill(sig, pgid)

					attempts -= 1
					sleep 1
				end

				# If after doing our best the @daemon is still running (pretty odd)...
				if ProcessFile.running(@daemon)
					$stderr.puts Rainbow("Daemon appears to be still running!").red
					return
				end

				# Otherwise the @daemon has been stopped.
				ProcessFile.clear(@daemon)
			end
		end
	end
end
