# -*- mode: perl; -*-
# vim:textwidth=78:

# $Id$

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

#
# This is the provision::util package used by provision(8)
# and it's modules. It need not be instantiated as an object
# as it holds no data.
#

package provision::util;

use strict;
use warnings;
use YAML;
use Fcntl qw(:DEFAULT :flock);
use File::Copy;
use File::stat;
use File::Basename;
use Text::Diff;
use Carp;
use IO::Handle;
use IPC::Open2;
use Data::Dumper;

my $VERSION = sprintf('%d.%03d',q$Revision$ =~ /: (\d+)\.(\d+)/);

use Exporter;
use base qw(Exporter);

our @EXPORT_OK = qw(call_helper checkin checkout commit_diff debug dry_run
                   file_grep get_fh get_lock info print_plugin_help
		   register_plugins show_diff verbose mywarn find_ld
		   clean_host);
our @EXPORT = qw(debug mywarn info verbose);
our %EXPORT_TAGS = (
                   plugin => [qw(checkin checkout commit_diff show_diff
                                 dry_run file_grep get_fh)],
                   provision => [qw(register_plugins get_lock call_helper
				    print_plugin_help find_ld clean_host)],
		   default => \@EXPORT,
                  );

use constant PLUGINS_DIR => '/usr/lib/provision/plugins';



##################################
#
# my_debug
#
# Prints debug info if $DEBUG is assigned
# with a pretty prefix
#
sub debug
{
        my ($msg) = @_;
        chomp($msg);

	my $callerinfo = '';

	#
	# This is kinda odd, but Perl doesn't define a call stack entry for
	# main(), so if we were called from main(), we have to use caller(0),
	# but anywhere else, we really want caller(1).
	#
	foreach my $level (1,0) {
		my @ret = caller($level);
		if (scalar(@ret) == 0) {
			next;
		}
		my $file = basename($ret[1]);
		my $line = $ret[2];
		my $sub = $ret[3];
		my @tmparray = split('::',$sub);
		$sub = $tmparray[-1];
		$callerinfo = "$file:$sub\(\):$line";
		last;
	}
        print "DEBUG:    $msg [$callerinfo]\n" if ($ENV{'ENABLE_DEBUG'});
}


##################################
#
# my_warn
#
# Prints warn info if $WARN is assigned
# with a pretty prefix
#
sub mywarn
{
        my ($msg) = @_;
        chomp($msg);
        print "WARN:     $msg\n" unless ($ENV{'SUPRESS_WARN'});
}


##################################
#
# my_info
#
# Prints info info with a pretty prefix
#
sub info
{
        my ($msg) = @_;
        chomp($msg);
        print "INFO:     $msg\n" unless (exists($ENV{'SUPRESS_INFO'}));
}


##################################
#
# checkout
#
# Use RCS to checkout a file
#
sub checkout
{
	my ($file) = @_;

	debug("checkout called for $file");

	my $st = stat($file)
		|| croak("Can't checkout $file, it doesn't exist!");

	if ( $st->mode & 0200 ) {
		# File is checked out, lets wait a bit
		for (my $count = 0; $count < 5; $count++) {
			debug("Waiting for $file to become unlocked"
				. " in RCS");
			sleep 3;
			last if ( ! ($st->mode & 0200) );
		}
	}

	croak("checkout of $file failed!") if ( $st->mode & 0200 );

	# use "and" because shell return values are reversed
	# from perl
	system("co","-l","-q","$file")
		&& croak("checkout of $file failed!");
}


##################################
#
# checkin
#
# Use RCS to checkin a file
#
sub checkin
{
	my ($file,$hostname,$config) = @_;

	debug("checkin called for $file");

	my $message = "provision: $hostname";
	if ($config->{'commit_msg'} ne ''){
		$message .= " message from user:\n  " . $config->{'commit_msg'};
	}
	system("ci","-u","-q","-m$message","$file")
		&& croak("checkin of $file failed!");
}


##################################
#
# file_grep
#
# Impliment grep(1)... mostly
#
# Takes in a file and a pattern, returns
# lines from the file that match that pattern
#
# More specifically, it returns a pointer to an array of matching lines.
#
# file_grep() will return undef on non-existing files.
#
sub file_grep
{
	my ($file,$pattern) = @_;

	if (! -r $file ) {
		return undef;
	}

	my $lines = [];
	debug("Greping $pattern from $file");
	open(GREPFILE,"<$file")
		|| die("Couldn't open file $file");
	@{$lines} = grep(/$pattern/i,<GREPFILE>);
	close(GREPFILE)
		|| die("Couldn't close file $file");

	return $lines;
}


##################################
#
# get_lock
#
# Impliments locking
#
# Takes in a lockfile, the number of attempts, and the amount
# of time to wait between attempts;
#
# Returns a pointer to a file handle
#
sub get_lock
{
	my ($lockfile, $attempts, $wait) = @_;
	sysopen(LOCK_FH, $lockfile, O_RDWR|O_CREAT)
		|| croak("coudln't open lockfile $lockfile");
	for (my $count = 0; $count < $attempts; $count++) {
		flock(LOCK_FH, LOCK_EX|LOCK_NB)
			&& return *LOCK_FH;
		debug("Couldn't lock $lockfile");
		sleep $wait;
	}
	return undef;
}


##################################
#
# Print something noting dryrun
#
sub dry_run
{
	if (scalar(@_) == 1 && $_[0] eq '') {
		print "DRYRUN:\n";
		return;
	}

	foreach my $out (@_) {
		my @lines = split(/\n/,$out);
		foreach my $line (@lines) {
			print "DRYRUN:   $line\n";
		}
	}
}


sub verbose
{
	if (scalar(@_) == 1 && $_[0] eq '') {
		print "VERBOSE:\n";
		return;
	}

	foreach my $out (@_) {
		my @lines = split(/\n/,$out);
		foreach my $line (@lines) {
			print "VERBOSE: $line\n";
		}
	}
}

##################################
#
# Given a hostname, user, command, and data, this function ssh's to the host
# as the user and runs the helper with the data on its STDIN.
#
# Note, this is really only meant for UNIX hosts, and seperate communication
# mediums should be implimented for devices in the appropriate plugins.
#
sub call_helper
{
	my ($plugin, $ssh_host, $config, $data) = @_;

	my $ssh_cmd = $config->{'provision_path'} . '/provision_helper'
			. " -p $plugin";

	my $ssh_user = $config->{'user'};

	my $cmd = "ssh -l $ssh_user $ssh_host \'($ssh_cmd) 2>&1\' 2>&1";
	debug($cmd);

	# Prepare IPC file handles
	my $reader = new IO::Handle;
	my $writer = new IO::Handle;

	# Fork SSH
	open2($reader, $writer, "$cmd") || die "Couldn't fork ssh: $!";

	my $tosend = YAML::Dump($config, $data);
	# Send data and close the filehandle so the child stops reading
	$writer->syswrite($tosend);
	$writer->close();

	debug("Data sent to helper");

	my $stdout = '';

	while (<$reader>) {
		$stdout .= $_;
	}
	print $stdout;

	$reader->close()
		|| die "Something went wrong with the SSH, can't close the"
			. " fh: $! ($?)";

	# We only ever fork one thing, and we want to block while we wait.
	wait();
	my $retval = $? >> 8;

	# We have to inverse shell returns to perl returns
	return ($retval) ? 0 : 1;
}


##################################
#
# Given a list of core options (to detect conflicts), 
# the command.
#
sub register_plugins
{
	my ($optionlist) = shift;

	#
	# Build list of perl modules in the directory
	#
	my $errors = {};
	my $plugins = {};


        #
	# FIXME: Use IO::Dir
        #
	opendir(PLUGDIR,PLUGINS_DIR)
		|| die("couldn't open " . PLUGINS_DIR);
	foreach my $dentry (readdir(PLUGDIR)) {
		if ($dentry =~ /.*\.pm$/) {
			my $plugin = substr($dentry, 0, -3);
			$plugins->{$plugin} = {};
		}
	}
	closedir(PLUGDIR)
		|| die("couldn't close " . PLUGINS_DIR);

	foreach my $plugin (keys(%{$plugins})) {
		if (!exists($errors->{$plugin})) {
			$errors->{$plugin} = 0;
		}

		eval "require provision::plugins::$plugin";

		if ($@) {
			mywarn("Couldn't load plugin $plugin, it doesn't exist"
                             . " or had compilation errors: \"$@\"");
			$errors->{$plugin}++;
			next;
		}

		$plugins->{$plugin}->{'ptr'} = "provision::plugins::$plugin";

		#
		# local_opts must return a point to a hash that looks like:
		#
		#   {'option1' => "help for option1",
		#    'option2' => "help for option2"}
		#
		no strict 'refs';
		my $opts = &{$plugins->{$plugin}->{'ptr'} . "::local_opts"}();
		use strict 'refs';

		if (!defined($opts)) {
			mywarn("Couldn't get options for plugin $plugin,"
                             . " it errored on local_opts()");
			$errors->{$plugin}++;
			next;
		}

		#
		# error-check the options
		#
		foreach my $option (keys(%{$opts})) {
			#
			# Check for short or obviously broken opts. We don't
			# allow plugins to register short opts, only long opts
			#
			if ($option =~ /[^\w\-]/
			    || $option =~ /^\d/
			    || length($option) < 2
			    || (exists($opts->{$option}->{'getopts'})
				&& $opts->{$option}->{'getopts'} =~ /[^=s@]/)) {
				mywarn("Option $option registered by plugin"
                                     . " $plugin is invalid. Attempting to"
                                     . " set short opts?");
				$errors->{$plugin}++;
				next;
			}

			#
			# Check for conflicts with core options
			#
			if (exists($optionlist->{$option})) {
				mywarn("Option $option registered by plugin"
					. " $plugin conflicts with existing"
					. " option.");
				$errors->{$plugin}++;
				next;
			}
			$optionlist->{$option} = undef;

		}
		$plugins->{$plugin}->{'opts'} = $opts;
	}

	foreach my $err (values(%{$errors})) {
		if ($err != 0) {
			return undef;
		}
	}

	return $plugins;
}


##################################
#
# Given a plugins object, assemble help output for the various plugins' options
# and print it out.
#
sub print_plugin_help
{
	my ($plugins) = @_;

	foreach my $plugin (keys(%{$plugins})) {
		next if (scalar(keys(%{$plugins->{$plugin}->{'opts'}}))
					== 0);
		print "   Options for $plugin module:\n\n";
		foreach my $opt (keys(%{$plugins->{$plugin}->{'opts'}})) {
			my $optobj = $plugins->{$plugin}->{'opts'}->{$opt};
			print '     --' . $opt;
			print " $optobj->{'args'}"
				if (exists($optobj->{'args'}));
			print "\n\t\t$optobj->{'help'}\n\n";
		}
	}
}


sub get_fh
{
	my ($name,$mode) = @_;

	my $fh = new IO::Handle;

	my $to_open = $name;
	$to_open = "/tmp/$name.$$";
	copy($name, $to_open)
		|| croak("creation of $to_open failed");

	open($fh, $mode . $to_open)
		|| croak("opening of $to_open failed");

	return $fh;
}

sub show_diff
{
	my $name = shift;

	unless ($ENV{'ENABLE_DRYRUN'} || $ENV{'ENABLE_VERBOSE'}) {
		return 1;
	}

	my $new = "/tmp/$name.$$";
	my $diff = diff($name,$new);
	if ($diff ne '') {
		if ($ENV{'ENABLE_DRYRUN'}) {
			dry_run($diff);
			dry_run('');
		} else {
			verbose($diff);
			verbose('');
		}
	}
}

sub commit_diff
{
	my $file = shift;

	my $new = "/tmp/$file.$$";

	if ($ENV{'ENABLE_DRYRUN'}) {
		unlink($new);
		return 1;
	}

	move($new, $file) || croak("Couldn't commit changes to $file");

	return 1;
}


sub find_ld
{
	my $host = shift;

	#
	# For callers like provision_helper, we support keeping a list
	# of what's been found so far, for effeciency.
	#
	# However, we don't require it.
	#
	my ($bad_ld_mods, $good_ld_mods) = ({},{});
	my $keeplist = 0;
	if (scalar(@_) == 2) {
		$keeplist = 1;
		$bad_ld_mods = shift;
		$good_ld_mods = shift;
		debug("Using hints objects: " . Dumper($good_ld_mods)
			. Dumper($bad_ld_mods));
	}

	foreach my $ld ($host->{'group'}, 'generic') {
		my $ld_name = 'provision::local_decision::' . $ld;
		if ($keeplist && exists($bad_ld_mods->{$ld_name})) {
			debug("$ld already in bad list, not attempting to"
				. ' load');
			next;
		}

		if ($keeplist && exists($good_ld_mods->{$ld_name})) {
			debug("$ld_name in good list, assuming good");
			return $good_ld_mods->{$ld_name};
		} else {
			eval "require $ld_name";
			if ($@) {
				debug("Failed to load $ld_name, trying next"
					. ' ld_plugin. Errors: ' . "\"$@\"");
				if ($keeplist) {
					$bad_ld_mods->{$ld_name} = undef;
				}
				next;
			}
			my $obj = $ld_name->new();;
			if ($keeplist) {
				$good_ld_mods->{$ld_name} = $obj
			}
			return $obj;
		}
	}

	# We were unable to find anything...
	return undef;
}

# This is a small function to allow to take a name passed on the command
# line and convert into an index into a provision::data object
sub clean_host
{
	my $name = shift;

	my ($a, undef) = split('=',$name);
	my $newname = $a;

	$newname =~ s/^[\+\~]//g;

	return $newname;
}


1;
