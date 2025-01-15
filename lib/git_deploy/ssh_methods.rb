class GitDeploy
  module SSHMethods
    private

    def sudo_cmd
      "sudo -p 'sudo password: '"
    end

    def system(*args)
      puts '[local] $ ' + args.join(' ').gsub(' && ', " && \\\n  ")
      super unless options.noop?
    end

    def run(cmd = nil, opt = {})
      cmd = yield(cmd) if block_given?
      cmd = cmd.join(' && ') if cmd.is_a?(Array)

      puts "[#{options[:remote]}] $ " + cmd.gsub(' && ', " && \\\n  ") if opt.fetch(:echo, true)

      return if options.noop?

      _, output = ssh_exec cmd do |ch, stream, data|
        case stream
        when :stdout then $stdout.print data
        when :stderr then $stderr.print data
        end
        ch.send_data(askpass) if data =~ /^sudo password: /
      end
      output
    end

    def run_test(cmd)
      status, = ssh_exec(cmd) {}
      status == 0
    end

    def ssh_exec(cmd)
      status = nil
      output = ''

      channel = ssh_connection.open_channel do |chan|
        chan.exec(cmd) do |ch, success|
          raise "command failed: #{cmd.inspect}" unless success

          # ch.request_pty

          ch.on_data do |c, data|
            output << data
            yield(c, :stdout, data)
          end

          ch.on_extended_data do |c, _type, data|
            output << data
            yield(c, :stderr, data)
          end

          ch.on_request 'exit-status' do |_ch, data|
            status = data.read_long
          end
        end
      end

      channel.wait
      [status, output]
    end

    # TODO: use Highline for cross-platform support
    def askpass
      tty_state = `stty -g`
      system 'stty raw -echo -icanon isig' if $?.success?
      pass = ''
      while char = $stdin.getbyte and ![13, 10].include?(char)
        if [127, 8].include?(char)
          pass[-1, 1] = '' unless pass.empty?
        else
          pass << char.chr
        end
      end
      pass
    ensure
      system "stty #{tty_state}" unless tty_state.empty?
    end

    def scp_upload(files)
      channels = []
      files.each do |local, remote|
        puts "FILE: [local] #{local.sub(LOCAL_DIR + '/', '')}  ->  [#{options[:remote]}] #{remote}"
        channels << ssh_connection.scp.upload(local, remote) unless options.noop?
      end
      channels.each { |c| c.wait }
    end

    def ssh_connection
      @ssh ||= begin
        ssh = Net::SSH.start(host, remote_user,
                             port: remote_port || 22,
                             keys: ['~/.ssh/id_rsa'],
                             # verbose: :debug
                             auth_methods: %w[publickey password])

        at_exit { ssh.close }
        ssh
      end
    end
  end
end
