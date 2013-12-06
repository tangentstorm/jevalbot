#!ruby -w
# jeval.rb -- irc bot for evaluating j commands
#
# by Zsban Ambrus <ambrus@math.bme.hu>
#
# WARNING: 
# Run jeval.rb to your own risk only, as the secure mode of the J interpreter
# might not be as secure as you think.  Also don't violate any rules set 
# by the irc network.
#
# NOTE:
# User configuration is now in a separate yaml file whose name you pass on 
# command line to jeval.rb.  
#
# TODO:
#  - document everything
#  - make sessions the default command
#  - make private messages reply in notices
#  - change the syntax for private messages so it evaluates without any prompt
#  - work around the invalid proverb evoke bug somehow, 
#       eg. change to another locale when restoring session (that would be a partial fix only)
#
#


require "socket"; 
require "thread";
require "net/http"; 
require "yaml";
require "enumerator";


begin # config

	$*.empty? and 
		fail "please use the name of config file as first command argument to jeval.rb";
	$CONF_DATA = Hash[];
	c = YAML.load_file($*[0]);
	Hash === c or fail "configuration must be a mapping";
	c.each do |k, v|
		$CONF_DATA[k.downcase] = v;
	end;
	module Kernel; 
		def conf key, *default;
			k = key.to_s.downcase;
			$CONF_DATA.fetch(k) do
				if block_given?;
					yield;
				elsif !default.empty?;
					default[0];
				else
					fail %Q(mandatory option "#{k}" missing from config file);
				end;
			end;
		end; 
	end;
	
end;


# preparations 1
begin
	wuid = conf(:jeval_uid, 1008) and (
		wuid == Process.euid or fail "not running as jeval user";
	);
	nice = conf(:jeval_nice, 5) and
		Process.setpriority Process::PRIO_PROCESS, 0, nice;
	if Process.const_defined?(:RLIMIT_AS) and mem = conf(:jeval_mem, 32*1024*1024);
		begin
			Process.setrlimit Process::RLIMIT_AS, mem;
		rescue Errno::EINVAL
			warn "got EINVAL from setrlimit RLIMIT_AS in parent process, this can mean RLIMIT_AS is unimplemented or that we tried to increase memory limit";
		end;
	end;
	Thread::abort_on_exception = 1;
	"1.8.7" == RUBY_VERSION or fail "wrong ruby version, expected 1.8.7, running under #{RUBY_VERSION}";
	trap "SIGPIPE", "SIG_IGN";
	Thread.new do conf(:master_timeout, 61).times do sleep 30*24*60*60; fail "master timeout"; end; end;
end;


# simple subs
begin;
	class String; 
		def blankctl!; tr!("\x00-\x1f\x7f", " "); self; end; 
		def blankctl; dup.blankctl!; end; 
		def escapectl; gsub(/[\x00-\x1f~\x7f-\x9f]/) { "~%02x" % $&[0] }; end;
		end;
	module Kernel; def sleep_forever; loop do sleep 24*60*60; end; end; end;
end;


# preparations 2
begin
	whost = conf(:jeval_host, "king") and (
		whost == `hostname`.chomp or fail "running on the wrong host";
	);
	if lockname = conf(:jeval_lock, nil);
		@lockfile = File.new(lockname, "r+");
		@lockfile.flock File::LOCK_EX | File::LOCK_NB or # note: this doesn't work over nfs
			fail "another instance of jeval is already running";
		@lockfile.truncate 0;
		@lockfile.puts Process.pid;
		@lockfile.flush;
		at_exit do
			@lockfile.truncate 0;
		end;
	end;
	puts "! jeval starting " + Time.now.to_s;
	Thread.new do 
		loop do 
			sleep 300; 
			puts "@ " + Time.now.strftime("%F %T");
		end; 
	end;
end;


# replacement wait
# (there's no real need for this, nor for the other two classes below)
module Waiter;
	@wait_handler = Hash[];
	@wait_result = Hash[]
	def Waiter.process_wait pid
		if h = @wait_handler[pid] and r = @wait_result[pid];
			h[r];
			@wait_handler.delete pid;
			@wait_result.delete pid;
		end;
	end;
	def Waiter.bkg_wait pid;
		@wait_handler[pid] = Proc.new;
		process_wait pid;
	end;
	trap "CLD" do
		while pid = begin Process.waitpid(-1, Process::WNOHANG);
				rescue Errno::ECHILD; (); end;
			@wait_result[pid] = $?;
			process_wait pid;
		end;
	end;
end;


# immutable case-preserving case-insensitive string
class CpString;
	class Object::String;
		def to_cpstring;
			CpString.new(self);
		end;
	end;
	def initialize s;
		@core = s.to_s.dup;
		@core.freeze;
		@cache = s.downcase;
		@cache.freeze;
	end;
	def to_s;
		@core;
	end;
	def to_cpstring;
		self;
	end;
	def canonical;
		@cache;
	end;
	def <=> b;
		CpString === b or
			return nil;
		@cache <=> b.canonical;
	end;
	def == b;
		CpString === b or
			return false;
		@cache == b.canonical;
	end;
	def eql? b;
		CpString === b or
			return false;
		@cache.eql? b.canonical;
	end;
	def hash;
		@cache.hash;
	end;
end;


# indexed binary heap library
class HHeap;

	# h = HHeap.new
	def initialize;
		@hash = Hash[];
		@heap = [];
	end;
	
	# h.put weight, key, value
	def put d, q, p = nil;
		delete q;
		k, kk = @heap.size, ();
		while 0 < k && d < @heap[kk = (k - 1) >> 1][0];
			@heap[k] = @heap[kk];
			@hash[@heap[k][1]] = k;
			k = kk;
		end;
		@heap[k] = [d, q, p];
		@hash[q] = k;
		return;
	end;
	
	def delete q;
		if m = @hash[q];
			_remove m;
		end;
	end;
	
	# weight, key, value = h.pop
	def pop;
		@heap.empty? and
			return;
		_remove 0;
	end;
	
	def _remove k;
		r = @heap[k];
		@hash.delete r[1];
		t = @heap.pop;
		k < (m = @heap.size) or
			return r;
		d = t[0];
		loop do
			j = (k << 1) + 1;
			j < m or
				break;
			j + 1 < m && @heap[j + 1][0] <= @heap[j][0] and
				j += 1;
			if @heap[j][0] < d
				@heap[k] = @heap[j];
				@hash[@heap[k][1]] = k;
				k = j;
			else
				break;
			end;
		end;
		@heap[k] = t;
		@hash[t[1]] = k;
		r;
	end;
	private :_remove;
	
	def size;
		@heap.size;
	end;
	def empty?;
		@heap.empty?;
	end;
	def each;
		@heap.each do |a|
			yield a;
		end;
	end;

	def [] p;
		k = @hash[p] and
			@heap[k];
	end;
	
end;


# forgetful hash
class ForgetHash;

	include Enumerable;
	attr :capacity;
	def initialize capacity;
		@capacity = capacity.to_i;
		@lock = Mutex.new;
		@core = HHeap.new;
		@serial = 0;
	end;
	def [] key;
		@lock.synchronize do
			wt, key, value = @core[key];
			@core.put((@serial += 1), key, value);
			value;
		end;
	end;
	def []= key, value;
		@lock.synchronize do
			@core.put((@serial += 1), key, value);
			while @capacity < @core.size;
				@core.pop;
			end;
		end;
	end;
	def delete key;
		@lock.synchronize do
			@core.delete key;
		end;
	end;
	def each;
		@core.each do |wgt, key, val|
			yield [key, val];
		end;
	end;
	def each_key;
		@core.each do |wgt, key, val|
			yield key;
		end;
	end;
	def empty?;
		@core.empty?;
	end;
	def size;
		@core.size;
	end;
	alias length size;
	def key? key;
		@lock.synchronize do
			!!@core[key];
		end;
	end;
	alias has_key? key?;
	alias include? key?;
	alias member? key?;
	def initialize_copy;
		fail "duping forgethash unimplemented";
	end;

end;


# sized queue variant where the data only has quantity, not quality
class SizedFluidQueue;
	def initialize capacity;
		@lock = Mutex.new;
		@endoverflow = ConditionVariable.new;
		@endunderflow = ConditionVariable.new;
		@capacity = capacity;
		@content = 0;
		0 < @capacity or fail "nonpositive capacity for sizedfluidqueue";
	end;
	attr_reader :content, :capacity;
	def produce amount;
		0 <= amount or fail "negative amount produced";
		@lock.synchronize do
			while @capacity < @content + amount;
				@content <= 0 and @endunderflow.broadcast;
				amount -= @capacity - @content;
				@content = @capacity;
				@endoverflow.wait(@lock);
			end;
			@content <= 0 and @endunderflow.broadcast;
			@content += amount;
		end;
	end;
	def consume amount;
		0 <= amount or fail "negative amount consumed";
		@lock.synchronize do
			while @content - amount < 0;
				@capacity <= @content and @endoverflow.broadcast;
				amount -= @content;
				@content = 0;
				@endunderflow.wait(@lock);
			end;
			@capacity <= @content and @endoverflow.broadcast;
			@content -= amount;
		end;
	end;
end;


# evaluating J
class JSpawn;

	class Abort < Exception; end;
	
	def jabort msg;
		@abort_msg = msg;
		@can_abort.try_lock and
			@user_thread.raise Abort;
	end;

	def jkill; 
		@jpid or return;
		begin Process.kill "TERM", @jpid; rescue Errno::ESRCH; end;
		sleep 2; 
		begin Process.kill "KILL", @jpid; rescue Errno::ESRCH; end;
	end; 

	def do_spawn;
		lsock, gsock, jep_arg = (), ();
		jfd = conf(:jeval_jfd, false);
		if jfd;
			@jconn, gsock = Socket.socketpair(Socket::PF_LOCAL, Socket::SOCK_STREAM, 0);
			jep_arg = gsock.fileno.to_s;
		else
			lsock = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0); 
			lsock.listen 1; 
			jep_arg = Socket.unpack_sockaddr_in(lsock.getsockname)[0].to_s; 
		end
		@jpid = fork do
			if jfd;
				@jconn.close;
				#gsock.fcntl(F_SETFD, gsock.fcntl(F_GETFD) & ~FD_CLOEXEC);
			end;
			nice = conf(:jspawn_nice, 5) and
				Process.setpriority Process::PRIO_PROCESS, 0, nice;
			if Process.const_defined?(:RLIMIT_AS) and mem = conf(:jspawn_mem, 32*1024*1024);
				begin
					Process.setrlimit Process::RLIMIT_AS, mem;
				rescue Errno::EINVAL
					warn "got EINVAL from setrlimit RLIMIT_AS in parent process, this can mean RLIMIT_AS is unimplemented or that we tried to increase memory limit";
				end;
			end;
			if Process.const_defined?(:RLIMIT_AS) and cpu = conf(:jspawn_cpu, 10*60);
				begin
					Process.setrlimit Process::RLIMIT_CPU, cpu;
				rescue Errno::EINVAL
					warn "got EINVAL from setrlimit RLIMIT_AS in parent process, this can mean RLIMIT_AS is unimplemented or that we tried to increase memory limit";
				end;
			end;
			exec(*conf(:jep_command) + [jep_arg]); 
		end; 
		Thread.new do 
			sleep conf(:jspawn_timeout, 9);
			jabort "|timeout";
		end; 
		if jfd;
			gsock.close;
		else
			@jconn = lsock.accept[0]; 
			lsock.close;
		end;
		Waiter.bkg_wait @jpid do 
			jabort "|abort4";
		end;
		sleep 0.1;
	end;

	(
		(*), CMDDO, CMDDOZ, CMDIN, CMDINZ, CMDWD, CMDWDZ, CMDOUT, 
		CMDBRK, CMDGET, CMDGETZ, CMDSETN, CMDSET, CMDSETZ, CMDED, CMDFL,
		CMDEXIT,
	) = (0..16).to_a;

	def jwrite c, t = 0, d = ""; 
		begin
			@jconn.write [c, t, d.length, d].pack("Cx3NNA*"); 
		rescue Errno::EPIPE; 
			jabort "|abort2";
		end;
	end; 
	
	def pumpread;
		loop do
			b = @jconn.read(12) or
				return @inputqueue.push([:err, "|abort"]);
			c, t, l = b.unpack("Cx3NN"); 
			d = @jconn.read(l) or
				return @inputqueue.push([:err, "|abort3"]);
			@inputqueue.push [c, t, d];
		end;
	end;
	
		def jwait expect = CMDDOZ;
		loop do
			c, t, d = @inputqueue.shift;
			case c;
				when CMDDOZ;
					if CMDDOZ == expect
						return t;
					elsif CMDIN == expect;
						return CMDDO;
					else
						jabort "|abort5";
					end;
				when CMDGETZ, CMDSETZ;
					c == expect or jabort "|abort7";
					0 == t or jabort "|abort8";
					return d;
				when CMDOUT;
					@output << d;
				when CMDEXIT;
					# noop
				when CMDIN;
					CMDIN == expect or 
						jabort "|abort11";
					return CMDINZ;
				when CMDWD;
					rt, rd = wd_handle t, d;
					jwrite CMDWDZ, rt, rd;
				when :err;
					jabort t;
				else
					fail "invalid type of reply from j interpreter: #{c}";
			end;
		end;
	end;

	JSPAWN_INIT2 = conf(:jspawn_init2, %q{(9!:33]50)](9!:21]2^25)](9!:7]'+++++++++|-')});
	JSPAWN_INIT3 = conf(:jspawn_init3, %Q{(9!:37]0 #{conf(:jspawn_cols, 388)-4} #{conf(:jspawn_lines, 6)-1} 0)]0 0$0});
	def do_pretalk;
		@output = "";
		@inputqueue = Queue.new;
		Thread.new do 
			pumpread; 
		end;
		jwrite CMDDO, 0, %q(9!:25]1); # secure
		jwait;
		jwrite CMDDO, 0, JSPAWN_INIT2;
		jwait;
		jwrite CMDDO, 0, JSPAWN_INIT3;
		jwait;
	end;
	
	SESSION_DUMPER = conf(:jspawn_sess_dumper, %q{state_jeval_ =: (,.5!:1)4!:1 i.4});
	SESSION_LOADER = conf(:jspawn_sess_loader, %q{4 :('(x)=:y(5!:0)';'0')/"1 state_jeval_});
	SESSION_NUM = conf(:jspawn_sessionnum, 16);
	SESSION_SIZE = conf(:jspawn_sessionsize, 256*1024);
	@@session_data = ForgetHash.new SESSION_NUM;
	
	NUMOUTLINES = conf(:jspawn_lines, 6);
	def do_talk;
		if @sessionkey and state = @@session_data[@sessionkey];
			jwrite CMDSETN, 0, "state_jeval_";
			jwrite CMDSET, 0, state;
			jwait CMDSETZ;
			jwrite CMDDO, 0, SESSION_LOADER;
			jwait or
				jabort "|abort9";
		end;
		outcnt = 0;
		want = CMDDO;
		@cmdarr.each do |cmd|
			@output = "";
			jwrite want, 0, cmd; 
			want = jwait CMDIN;
			@output.each do |l| 
				l.chomp!;
				outcnt < NUMOUTLINES and
					@outproc[l.blankctl![0, conf(:jspawn_cols, 388)]];
				outcnt += 1;
			end;
		end;
		CMDDO == want or
			jabort "|need input";
		0 < outcnt or
			@outproc["|ok"];
		if @sessionkey;
			jwrite CMDDO, 0, SESSION_DUMPER;
			jwait or
				jabort "|abort10";
			jwrite CMDGET, 0, "state_jeval_";
			state = jwait CMDGETZ;
			if state.size < SESSION_SIZE;
				@@session_data[@sessionkey] = state;
			else
				@outproc["|state size error"];
			end;
		end;
	end;
	
	def self.clearsession sessionkey;
		@@session_data.delete sessionkey;
	end;
	def self.copysession tokey, fromkey;
		@@session_data[tokey] = @@session_data[fromkey];
	end;
	def self.listsessions;
		@@session_data.each_key do |k|
			yield k;
		end;
	end;
	
	def abortmsg;
		@outproc[@abort_msg];
	end;
	
	def run cmdarr, sessionkey = nil;
		@cmdarr = cmdarr;
		@sessionkey = sessionkey;
		@can_abort = Mutex.new;
		@jpid = ();
		begin
			@user_thread = Thread.current;
			@abort_msg = "|abort1";
			wd_init;
			do_spawn;
			do_pretalk;
			do_talk
			@can_abort.lock;
		rescue Abort;
			abortmsg;
		ensure
			@can_abort.try_lock;
			jkill;
		end;
	end;
	
	def retrymsg;
		@outproc["|ask later"];
	end;
	
	@@active_lock = Mutex.new;
	@@active = Hash[];
	
	def bkg *arg;
		@outproc = Proc.new;
		Thread.new do
			toomany = ();
			@@active_lock.synchronize do
				@@active[self] = 1;
				toomany = conf(:jspawn_parallel, 7) < @@active.size;
			end;
			if !toomany;
				run(*arg);
			else
				retrymsg;
			end;
			@@active_lock.synchronize do
				@@active.delete self;
			end;
		end;
	end;
	
	WORD_UNPACK_TEMPLATE = Hash[0xe0, "N", 0xe1, "V", 0xe2, "x4N", 0xe3, "Vx4"];
	def unpack_jnoun s;
		pt = WORD_UNPACK_TEMPLATE[s[0]];
		nflag, s0 = s.unpack("#{pt}a*");
		unpack_jnoun1 pt, s0;
	end;
	def unpack_jnoun1 pt, s0;
		ntype, nlen, nrank, s1 = s0.unpack("#{pt}3a*");
		shap, s2 = s1.unpack("#{pt}#{nrank}a*");
		case ntype;
			when 2;
				s2.unpack("a#{nlen}")[0];
			else
				nil;
		end;
	end;
	
	def wd_init;
		@wd_num = conf(:wd_max, 4096);
		@wd_bbquery_num = conf(:wd_bbquery_max, 3);
	end;
	
	def wd_handle t, d;
		0 <= (@wd_num -= 1) or
			jabort "|too many wd";
		v = unpack_jnoun d;
		puts "! wd #{t} \"#{d.escapectl}\" #{v.inspect}";
		case t;
			when 0;
				String === v or
					jabort "|invalid wd0";
				[0, v];
			when 1;
				jabort "|disabled wd1";
				0 <= (@wd_bbquery_num -= 1) or
					jabort "|too many wd1";
				String === v or
					jabort "|invalid wd1";
				r = Irc.bbquery v[0,384];
				[0, r];
			else
				jabort "|invalid wd";
		end;
	end;
	
end;


module Irc; end; # irc
Irc.instance_eval do

	IRCNICK = conf(:ircnick);
	IRCCHAN = Hash[];
	def get_ircchan channame;
		IRCCHAN[channame.to_cpstring] ||= Hash[];
	end;
	conf(:ircchan).each do |chan, opts|
		ent = get_ircchan chan;
		opts.each do |k, v| ent[k.downcase.to_sym] = v; end;
	end;
	
	IRC_BOTIGNORE = Hash[];
	(conf(:irc_botignore) || []).each do |nick| IRC_BOTIGNORE[nick.to_cpstring] = 1; end;
	IRC_IGNORE = Hash[];
	(conf(:irc_ignore) || []).each do |nick| IRC_IGNORE[nick.to_cpstring] = 1; end;
	
	IRC_QUEUESIZE = conf(:irc_queuesize, 128);
	@ircputsqueue = Queue.new;
	def ircputs *msgs;
		msgs.each do |msg|
			m = msg.tr("\r\n", "  ");
			@ircputsqueue.push m;
		end;
		while IRC_QUEUESIZE < @ircputsqueue.size;
			@ircputsqueue.shift;
		end;
	end;
	def ircprivmsg dest0, text;
		dest0 =~ /\A(["-~\xa0-\xff]{1,512})/ or fail "invalid destination";
		dest = $1;
		text.blankctl![0, 512];
		text.empty? and text += " ";
		ircputs "PRIVMSG " + dest + " :" + text;
	end;

	NICK_QREGEXP = Regexp.new %q/(?i)\A/ + IRCNICK + %q/(?!\w)/;
	SHORT_REGEXP = Regexp.new \
		%q/\A(/ + 
		Regexp.quote(conf(:irc_shortprefix, "]")) + 
		%q/[\.\:]*)/ +
		(if conf(:irc_shortspace, true); %q/\s/ else %q// end) +
		%q/(.*)/;
	SHORT_ENABLE = conf(:irc_shortenable, false);
	IRC_ADMINS = Hash[]
	(conf(:irc_admins) || []).each do |nick| IRC_ADMINS[nick.to_cpstring] = 1; end;

	@hold_data = ForgetHash.new(conf(:irc_holdnum, 32));
	def hold line, holdkey;
		dat = @hold_data[holdkey] ||= [];
		dat << line;
		if conf(:irc_holdlines, 128) < dat.size;
			dat.clear;
			return false;
		end;
		true;
	end;
	def unhold holdkey;
		@hold_data.delete holdkey;
	end;
	
	class SessionPermError < Exception; end;
	@working = ForgetHash.new(conf(:irc_numwduser, 256));
	def get_working workkey;
		workkey or
			return nil;
		user, channel = workkey;
		channel ||= "_priv";
		u = (@working[user.to_cpstring] ||= ForgetHash.new(conf(:irc_numwdperuser, 32)));
		u[channel.to_cpstring] || expand_sessionkey(workkey, "", false);
	end;
	def expand_sessionkey workkey, skey, read_only;
		user, channel = workkey;
		channel ||= "_priv";
		user =~ /\,/ and fail "nickname with comma";
		channel =~ /\,/ and fail "channel name with comma";
		(skey ||= "") =~ /\A(?:([\!-\+\--\~]*)\,)?([\!-\+\--\~\xa0-\xff]{1,64})?\z/ or
			fail SessionPermError;
		sessionsuffix = $2 || channel;
		sessionowner = (
			if !$1; user;
			elsif read_only; $1;
			elsif $1.empty?; "";
			elsif user.downcase == $1.downcase; user;
			else fail SessionPermError;
			end
		);
		r = (sessionowner + "," + sessionsuffix).to_cpstring;
		#p [:expand_sessionkey, workkey, skey, read_only, :"=>", r];
		r;
	end;
	def set_working workkey, skey;
		user, channel = workkey;
		channel ||= "_priv";
		sessionkey = expand_sessionkey workkey, skey, false;
		u = (@working[user.to_cpstring] ||= ForgetHash.new(conf(:irc_numwdperuser, 32)));
		u[channel.to_cpstring] = sessionkey;
		return sessionkey;
	end;
	
	def runj cmd, anstarget, ansprefix, holdkey, workkey = nil;
		sessionkey = get_working workkey;
		holddat = @hold_data[holdkey] || [];
		@hold_data.delete holdkey;
		!holddat.empty? || cmd =~ /\S/ or return;
		cmdarr = holddat + [cmd];
		puts "] " + (sessionkey || "").to_s.escapectl + " " + cmdarr.map {|l| l.escapectl }.join("~%");
		JSpawn.new.bkg(cmdarr, sessionkey) do |l|
			ircprivmsg anstarget, ansprefix + l;
		end;
	end;

	def gotcmd cmdname, punctuation, args, origin, chan;
		admin = !chan && IRC_ADMINS[origin.to_cpstring];
		botignore = IRC_BOTIGNORE[origin.to_cpstring];
		botignore && chan and
			return;
		replytarget = chan || origin;
		reply = proc do |s|
			if chan;
				ircprivmsg replytarget, origin + ", " + s;
			else
				ircprivmsg replytarget, s;
			end;
		end;
		if !cmdname;
			cmdname = "session";
			punctuation =~ /\.\.\z/ and
				cmdname = "hold"; 
			#punctuation =~ /\:\:\z/ and
				#cmdname = "session";
		end;
		case cmdname.downcase;
			when "transient", "alone", "nosess";
				botignore and return;
				holdkey = [origin.to_cpstring, (if chan; chan.to_cpstring else nil end)];
				runj args, replytarget, (if chan; origin + ": " else "" end), holdkey;
			when "", "eval", "jeval", "evalj", "eval_j", "ijx", IRCNICK.downcase, "session", "sess", "persistent";
				botignore and return;
				conf(:jspawn_sess, false) or return;
				runj args, replytarget, (if chan; origin + ": " else "" end), [origin.to_cpstring, (if chan; chan.to_cpstring else nil end)], [origin, chan];
			when "list", "ls", "dir";
				botignore and return;
				s = "";
				JSpawn.listsessions do |key|
					k = key.to_s;
					if 256 < s.length + 1 + k.length;
						reply["open sessions are:", s];
						s.clear;
					else
						s << " " + k;
					end;
				end;
				s.empty? or
					reply["open sessions are: " + s];
				reply["done list"];
			when "current", "curr", "pwd", "wd", "working";
				botignore and return;
				reply["working session is " + get_working([origin, chan]).to_s];
			when "change", "cd", "chdir", "cwd";
				botignore and return;
				new = "";
				args =~ /(\S+)/ and new = $1;
				begin
					success = set_working([origin, chan], new);
					reply["changed to " + success.to_s];
				rescue SessionPermError;
					reply["error changing working session"];
				end;
			when "home";
				botignore and return;
				success = set_working([origin, chan], "");
				reply["changed to " + success.to_s];
			when "kill", "clear";
				botignore and return;
				begin
					to = (
						if args =~ /(\S+)/;
							expand_sessionkey([origin, chan], $1, false);
						else
							to = get_working([origin, chan]);
						end
					);
					JSpawn.clearsession to;
					reply["cleared " + to.to_s];
				rescue SessionPermError;
					reply["error finding other session"];
				end;
			when "new", "clean", "reset", "changenew";
				botignore and return;
				new = "";
				args =~ /(\S+)/ and new = $1;
				begin
					success = set_working([origin, chan], new);
					JSpawn.clearsession success;
				rescue SessionPermError;
					reply["error changing working session"];
				else
					reply["changed to " + success.to_s + " and cleared it"];
				end;
			when "load";
				botignore and return;
				new = "";
				args =~ /(\S+)/ and
					new = $1;
				begin
					from = expand_sessionkey([origin, chan], new, true);
					to = get_working([origin, chan]);
					JSpawn.copysession(to, from);
				rescue SessionPermError;
					reply["error finding other session"];
				else
					reply["copied " + to.to_s + " from " + from.to_s];
				end;
			when "save";
				botignore and return;
				new = "";
				args =~ /(\S+)/ and
					new = $1;
				begin
					from = get_working([origin, chan]);
					to = expand_sessionkey([origin, chan], new, false);
					JSpawn.copysession(to, from);
				rescue SessionPermError;
					reply["error finding other session"];
				else
					reply["copied " + to.to_s + " from " + from.to_s];
				end;
			when "hold", "cont", "buf", "buffer";
				botignore and return;
				hold args[0, 1024], [origin.to_cpstring, (if chan; chan.to_cpstring else nil end)] or
					reply["held too much, dropped all"];
			when "die", "quit", "exit", "fail", "raise", "error";
				admin or return;
				fail "admin quit command from #{origin}";
			when "cquit";
				admin or return;
				ircputs "QUIT";
			when "ping", "echo";
				reply["pong: " + args];
			when "source";
				reply["jevalbot source is http://www.math.bme.hu/~ambrus/pu/jevalbot.tgz"];
			when "join";
				admin or return;
				args =~ /(\S+)/ or return;
				chan1 = $1;
				get_ircchan(chan1)[:join];
				ircputs "JOIN :" + chan1.blankctl;
				reply["done join"];
			when "part", "leave";
				admin or return;
				args =~ /(\S+)/ or return;
				chan1 = $1;
				get_ircchan(chan1)[:join] = ();
				ircputs "PART :" + chan1.blankctl;
				reply["done part"];
			when "short";
				admin or return;
				args =~ /(\S+)/ or return;
				chan1 = $1;
				get_ircchan(chan1)[:short] = 1;
				reply["done short"];
			when "long", "noshort", "unshort";
				admin or return;
				args =~ /(\S+)/ or return;
				chan1 = $1;
				get_ircchan(chan1)[:short] = ();
				reply["done noshort"];
			when "botlist", "botignorelist";
				IRC_BOTIGNORE.keys.sort.map {|n| n.to_s }.each_slice(12) do |l|
					reply["bot: " + l.join(" ")];
				end;
				reply["done botlist"];
			when "botignore", "bot", "isbot";
				change = ();
				args.scan(/(\S+)/) do
					admin || origin.downcase == $1.downcase and (
						IRC_BOTIGNORE[$1.to_cpstring] = 1;
						change = 1;
					);
				end;
				change and reply["done botignore"];
			when "ignore";
				change = ();
				args.scan(/(\S+)/) do
					admin || origin.downcase == $1.downcase and (
						IRC_IGNORE[$1.to_cpstring] = 1;
						change = 1;
					);
				end;
				change and reply["done ignore"];
			when "ambot", "amabot", "iambot", "iamabot", "meisbot";
				IRC_BOTIGNORE[origin.to_cpstring] = 1;
				reply["done ambot"];
			when "unignore", "unbot", "unbotignore", "botunignore";
				admin or return;
				args.scan(/(\S+)/) do
					IRC_BOTIGNORE.delete $1.to_cpstring;
					IRC_IGNORE.delete $1.to_cpstring;
				end;
				reply["done unignore"];
		end;
		
	end;
	def gotchan line, origin, chan;
		if line =~ NICK_QREGEXP;
			if $' =~ /(?ix) 
				\A\s* (?:
					([\:\[\]\>\=\)][\.\:]*) (?: \s* ([a-z][a-z0-9_]+)\: )? |
					(?:[\,\;]\s*)? ([a-z][a-z0-9_]+) \s* ([\:\[\]\>\=\)][\.\:]*)
				) \s* (.*)
				/;
				keyword = $2 || $3;
				args = $+;
				punctuation = $1 || $4;
				gotcmd keyword, punctuation, args, origin, chan;
			end;
		elsif SHORT_ENABLE and get_ircchan(chan)[:short] and
			line =~ SHORT_REGEXP;
			punctuation = $1;
			args = $+;
			gotcmd nil, punctuation, args, origin, chan;
		end;
	end;
	def gotpriv line, origin;
		if line =~ /(?ix)
			\A (?:
				([\:\[\]\>\=\)][\.\:]*)\s |
				([\)][\.\:]*) |
				([a-z][a-z0-9_]+) \s* ([\:\[\]\>\=\)][\.\:]*)
			) \s* (.*)
			/;
			keyword = $3;
			punctuation = $1 || $2 || $4;
			args = $+;
			gotcmd keyword, punctuation, args, origin, nil;
		end;
	end;
	conf(:irc_priveval, true) or warn "config option irc_priveval is obsolate, private messages are now always enabled";

	BBNICK = conf(:bbnick, "buubot");
	@bbquery_lock = Mutex.new;
	@bbquery_answer = nil;
	@bbquery_answer_cond = ConditionVariable.new;
	def gotbbreply str;
		@bbquery_answer = str;
		@bbquery_lock.synchronize do
			@bbquery_answer_cond.broadcast;
		end;
	end;
	def bbquery cmd;
		@bbquery_lock.synchronize do
			@bbquery_answer = nil;
			ircputs "PRIVMSG #{BBNICK} :" + cmd[0,384].blankctl;
			this_timedout = false;
			Thread.new do
				sleep conf(:bbquery_timeout, 5);
				@bbquery_lock.synchronize do
					this_timedout = true;
					@bbquery_answer_cond.broadcast;
				end;
			end;
			while !@bbquery_answer && !this_timedout;
				@bbquery_answer_cond.wait @bbquery_lock;
			end;
			@bbquery_answer || "";
		end;
	end;

	def ircgot fullorigin, command, args, full;
		origin = ();
		fullorigin and fullorigin =~ /\A([^!]+)/ and origin = $1;
		case command.upcase;
			when "PING";
				ircputs "PONG " + args.join(" ");
			when "477", "442", "403";
				# ignore
			when "404"; # ERR_CANNOTSENDTOCHAN
				if conf(:irc_nomoderate, false);
					fail "irc can not speak on channel: #{full}";
				end;
			when "401"; # ERR_NOSUCHNICK
				# ignore
			when "462";
				if !conf(:irc_doublelogin, false);
					fail "irc double login: #{full}";
				end;
			when "JOIN";
				unhold [origin.to_cpstring, args[0].to_cpstring];
			when "KICK";
				if conf(:irc_nokick, false);
					IRCNICK.downcase == args[1].downcase and
						fail "irc kick: #{full}";
				end;
			when "PRIVMSG";
				if !origin;
					# message from server, ignore
				elsif IRC_IGNORE[origin.to_cpstring];
					# ignore message
				elsif BBNICK.downcase == origin.downcase;
					puts "! got reply from buubot: #{args[1].escapectl}";
					gotbbreply args[1];
				elsif IRCNICK.downcase == args[0].downcase;
					gotpriv args[1], origin;
				else
					gotchan args[1], origin, args[0];
				end;
			when "ERROR", /\A[4-5]/;
				fail "error from irc client: #{full}";
		end;
	end;
	
	
	sleep 1;
	@ircconn = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0);
	irchost = conf(:irc_hostname, "irc.freenode.net");
	ircport = conf(:irc_port, 6667);
	ircsockaddr = Socket.pack_sockaddr_in(ircport, irchost);
	ircportn, irchostn = Socket.unpack_sockaddr_in(ircsockaddr);
	puts "! about to connect to tcp #{irchost}/#{ircport} (#{irchostn}/#{ircportn})";
	@ircconn.connect ircsockaddr;
	puts "! connection succeeded";
	Thread.new do 
		while l = @ircconn.gets; 
			l.gsub!(/[\r\n]*\z/) { "" };
			puts "< " + l.escapectl;
			l =~ /\S/ or next;
			l =~ /\A(?:\:([^ ]*)\ +)?(.*?)(?:\ \:(.*))?\z/ or 
				fail "error parsing message from irc server";
			origin, mostargs, trailingarg = $1, $2, $3;
			command, *args = mostargs.scan(/[^ ]+/);
			command =~ /\A\w+\z/ or 
				fail "error parsing2 message from irc server";
			trailingarg and args << trailingarg;
			ircgot(origin, command, args, l);
		end; 
		fail "irc server disconnected"; 
	end;
	IRC_CREDITDELAY = conf(:irc_creditdelay, 4);
	IRC_CHARPERCREDIT2 = conf(:irc_charpercredit2, 100);
	IRC_EXTRAPERLINE = conf(:irc_extraperline, 8);
	@ircputscredit = SizedFluidQueue.new conf(:irc_creditmax2, 1000);
	Thread.new do
		@ircputscredit.produce conf(:irc_creditstart, 600);
		loop do
			sleep IRC_CREDITDELAY;
			@ircputscredit.produce IRC_CHARPERCREDIT2;
		end;
	end;
	Thread.new do
		while msg = @ircputsqueue.shift;
			@ircputscredit.consume IRC_EXTRAPERLINE + msg.size;
			puts "> " + msg.gsub(/(\bnickserv\b.*\bidentify\b).*/im) { $1 + " ???" }.blankctl!;
			@ircconn.print msg, "\r\n";
		end;
	end;
	ircpass = File.open(conf(:irc_nickservpass_file)).readline.chomp;
	irc_username = conf(:irc_username, `whoami`.chomp!);
	irc_logincmd = [
		"PASS 0", "NICK #{IRCNICK}", "USER #{irc_username} 0 0 :#{conf(:irc_realname, "jevalbot")}",
		"PRIVMSG nickserv :identify #{ircpass}", 
	];
	if !conf(:irc_doublelogin, false);
		ircputs(*irc_logincmd);
	end;
	sleep 5;
	IRCCHAN.each do |chan, ent|
		IRCCHAN[chan][:join] and
			ircputs "JOIN :" + chan.to_s.blankctl;
	end;
	sleep_forever;
	
end;


__END__
