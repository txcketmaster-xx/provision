# -*- mode: perl; -*-
# vim:textwidth=78:

# $Id: dns.pm,v 1.26 2007/10/12 02:34:23 phil Exp $

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
# DNS module of provisioning tool
#

package provision::plugins::dns;

use strict;
use warnings;
use Scalar::Util 'reftype';
use Net::Ping;
use File::Basename;
use Carp;
use lib '/usr/lib';
use provision::util qw(:default :plugin);
use provision::data;

my $VERSION = sprintf('%d.%03d',q$Revision: 1.26 $ =~ /: (\d+)\.(\d+)/);

sub new
{
	my $package = shift;
	return bless({},$package);
}

sub local_opts
{
	return {};
}

sub run
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};
        unless ($ld->check_do_plugin($host,$config,'dns')) {
                return 1;
        }

	my $zonepath = $config->{'zonepath'};

	debug("changing directories to $zonepath");
	chdir($zonepath)
		|| croak("I can't chdir into $zonepath!");

	if ($host->{'action'} == provision::data::ACTION_ADD) {
		return $self->allocate($host,$config);
	} elsif ($host->{'action'} == provision::data::ACTION_REMOVE) {
		return $self->deallocate($host,$config);
	} elsif ($host->{'action'} == provision::data::ACTION_ALIAS) {
		return $self->alias($host,$config);
	} else {
		mywarn('This action is not something I support');
		return 1;
	}

	# If we get here, something's pretty messed up
	return 0;
}

sub allocate
{
	my $self = shift;
	my ($host,$config) = @_;
	my ($out,$f1,$f2,$f3,$f4,$ip,$zonefile);

	my $ld = $config->{'ld_ptr'};

	#
	# lets get our information together
	#
	my $range = $ld->get_range($host,$config);
	if ($range eq '') {
		croak('I don\'t know of an IP range for host '
			. $host->{'hostname'});
	}

	my $rev_zonefile_list = $self->get_rev_zonefile_list($range);
	my $fwd_zonefile = $self->get_fwd_zonefile($host,$config);

	if (scalar(@{$rev_zonefile_list}) <= 0
			|| $fwd_zonefile eq '') {
		croak('Couldn\'t determine zonefile information');
	}

	
	#
	# Check to see if we can find it in forward
	#
	my $fwd = '';
	$fwd = $self->check_name_in_fwd($host,$config,$fwd_zonefile);

	#
	# Check to see if we can find it in reverse
	#
	my $rev = '';
	$rev = $self->check_name_in_rev($host,$config,$rev_zonefile_list);

	if (!defined($fwd) || !defined($rev)) {
		croak("I found something I don't support - you're probably"
			. " trying to allocate something that's an NS/CNAME");
	}

	#
	# At this point, $fwd and $rev will hold IPs
	# If the host was defined in the respective sides of DNS
	#

	#
	# So now we cross-check it:
	#  - we see if what we found in each side was the same
	#  - we see if those IPs show up on the other side with different hosts
	# 
	# This will also tell us what we need to do
	#
	my ($need_fwd,$need_rev) = $self->cross_check($host,$host,$fwd,$rev,
		$fwd_zonefile);

	
	#
	# OK, now we know what needs to be done, lets do it
	#
	if ($need_fwd == 1 && $need_rev == 1) {
		$ip = $self->allocate_ip_and_reverse($host,$config,
			,$fwd_zonefile,$rev_zonefile_list);
		$self->add_forward($fwd_zonefile,$ip,$host,$config);
	} elsif ($need_fwd == 1) {
		info('Adding forward for pre-existing reverse');
		$self->add_forward($fwd_zonefile,$rev,$host,$config);
	} elsif ($need_rev == 1) {
		info('Adding reverse for pre-existing forward');
		($f1,$f2,$f3,$f4) = split(/\./,$fwd);
		checkout("$f1.$f2.$f3");
		$self->add_reverse("$f1.$f2.$f3",$f4,$host);
		checkin("$f1.$f2.$f3",$host->{'hostname'},$config);
	}

	unless ($need_fwd == 0 && $need_rev == 0) {
		unless($self->commit_dns()) {
			return 0;
		}
	}
	#
	# All plugins should print a final status message
	#
        if ($need_fwd == 0 && $need_rev == 0) {
                info('DNS: DNS already allocated for '
                        . $host->{'hostname'});
        } else {
		info("DNS: Allocated $ip for $host->{'hostname'}");
        }
        return 1;

}

sub deallocate
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};
	my $zonepath = $config->{'zonepath'};

	debug("changing directories to $zonepath");
	chdir($zonepath)
		|| croak("I can't chdir into $zonepath!");

	#
	# lets get our information together
	#
	my $range = $ld->get_range($host,$config);
	unless (defined($range)) {
		debug($host->{'hostname'} . ' wasn\'t mapped to an IP,'
			. ' so we won\'t check the zonefile it\'s supposed'
			. ' to be in, just where it looks like it\'ll be');
	}

	my $fwd_zonefile = $self->get_fwd_zonefile($host,$config);

	if ($fwd_zonefile eq '') {
		croak('Couldn\'t determine forward zonefile information');
	}

	# Keep track of if we actually deallocate anything
	my $did_dealloc = 0;

	# Remove the forward entry, get back any IPs it was pointed to
	my ($ips,$was_alias) = $self->remove_name_from_fwd($host,$fwd_zonefile,
							$config);
	unless (defined($ips)) {
		croak('Failed to remove ' . $host->{'hostname'} . ' from forward'
			. ' zonefile');
	}

	if (scalar(@{$ips}) > 0 || $was_alias) {
		$did_dealloc = 1;
	}

	my %files_checked;

	# If it maps to a range, check the reverse zones we _think_ it
	# should be in.
	if (defined($range) && $range ne '') {
		my $rev_zonefile_list = $self->get_rev_zonefile_list($range);
		%files_checked = map { $_ => undef } @{$rev_zonefile_list};
		my $ret = $self->remove_name_from_rev($host,$rev_zonefile_list,
								     $config);
		unless(defined($ret)) {
			croak("Failed to remove $host->{'hostname'} from"
				. ' reverse zonefile');
		}
		if ($ret > 0) {
			$did_dealloc = 1;
		}
	}

	foreach my $ip (@{$ips}) {
		my $rev_zonefile_list = $self->get_rev_zonefile_list($ip);


		# The IP should only be one place!
		if (scalar(@{$rev_zonefile_list}) > 1) {
			croak('I was told the IP should exist in more than'
				. ' once place. That\'s not right.');
		} elsif (scalar(@{$rev_zonefile_list}) < 1) {
			croak('I was unable to determine the reverse zonefile'
				. " for $ip\n");
		}

		# If the file we have has already been checked, move on...
		if (exists($files_checked{$rev_zonefile_list->[0]})) {
			next;
		}

		my $ret = $self->remove_ip_from_rev($host,
					@{$rev_zonefile_list}[0],$ip,$config);
		unless (defined($ret)) {
			croak('Failed to remove matching reverse for '
				. $host->{'hostname'});
		}
		if ($ret > 0) {
			$did_dealloc = 1;
		}
	}
	
	unless ($self->commit_dns()) {
		return 0;
	}

	if ($did_dealloc) {
		info("DNS: Deallocated $host->{'hostname'}");
	} else {
		info('DNS: No deallocation needed');
	}

	return 1;
}

sub alias
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	my $zonepath = $config->{'zonepath'};

	debug("changing directories to $zonepath");
	chdir($zonepath)
		|| croak("I can't chdir into $zonepath!");

	#
	# It's an alias - but if it's a FQDN, then we're going to check
	# the appropriate reverse and make sure it's not there, so we need
	# the range it would be in if it wasn't an alias.
	#
	my $check_reverse = 0;
	my $rev_zonefile_list = [];
	my $range = $ld->get_range($host,$config);
	if (defined($range) && $range ne '') {
		$check_reverse = 1;
		$rev_zonefile_list = $self->get_rev_zonefile_list($range);
	}

	debug('Getting zonefile lists');
	my ($fwd_zonefile);
	$fwd_zonefile = $self->get_fwd_zonefile($host,$config);

	#
	# Check to see if we can find it in forward
	#
	debug('Checking for existance in fwd');
	my $fwd = '';
	$fwd = $self->check_name_in_fwd($host,$config,$fwd_zonefile);

	#
	# Check to see if we can find it in reverse
	#
	if ($check_reverse) {
		debug("Checking for existance in rev");
		my $rev = '';
		$rev = $self->check_name_in_rev($host,$config,$rev_zonefile_list);
		if (!defined($rev) || $rev ne '') {
			mywarn($host->{'hostname'} . ' appears to have a reverse'
                             . ' allocation in DNS!');
			return 0;
		}
	}

	if (!defined($fwd) || $fwd ne '') {
		mywarn($host->{'hostname'} . ' appears to already be used,'
			. ' and DNS states you can\'t be a CNAME and anything'
			. ' else. Sorry.');
		return 0;
	}

	debug("Adding CNAME to $fwd_zonefile");
	unless ($self->add_cname($host,$fwd_zonefile,$config)) {
		return 0;
	}

	debug('Comming DNS');
	unless ($self->commit_dns()) {
		return 0;
	}

	info("DNS: Alias added: $host->{'hostname'}");

	return 1;
}


##############################
#
# Helper Subs
#
##############################

#
# This function takes a CIDR address and returns all the associated reverse
# zonefiles.
#
# However, if passed in a plain IP, it just passes back the appropriate
# zonefile.
#
sub get_rev_zonefile_list
{
	my $self = shift;
	my ($range) = @_;

	my @list_of_ranges = ();
	my $not_range = 0;
	my (@list);
	my ($ip,$mask);
	my $reftype = reftype($range);
	if (defined($reftype) && $reftype eq 'ARRAY') {
		push(@list_of_ranges,@{$range});
	} else {
		push(@list_of_ranges,$range);
		if ($range !~ /\//) {
			$not_range = 1;
		}
	}

	foreach my $lrange (@list_of_ranges) {

		if ($not_range) {
			$ip = $lrange;
		} else {
			($ip,$mask) = split(/\//,$lrange);
		}

		#
		# The original version of provision assumed all CIDR addrs
		# were passed in like 'x.y.z/mm' - but it's more correct to
		# say 'w.x.y.0/mm' - so we need to support both.
		#
		my ($bitone,$bittwo,$bitthree) = split('\.',$ip);
		if ($bitthree =~ /\./) {
			($bitthree,undef) = split('\.',$bitthree);
		}

		# If we were just passed in an IP, we're good to go...
		if ($not_range) {
			push(@list,"$bitone.$bittwo.$bitthree");
			next;
		}

		if ($mask > 24) {
			croak("Subnet masks must be >= 24, but $mask was"
				. ' requested.');
		}

		if ($mask < 16) {
			mywarn('A subnet mask of less than 20 was requested.'
                             . ' This is is probably a mistake.');
		}

		# This is a neat trick - there are 2^(32-mask-8) /24's in a
		# given mask. That took me a bit to figure out. :)
	
		my $numfiles = 2**(32-$mask-8);

		for (my $i = 0; $i < $numfiles; $i++) {
			push(@list,$bitone . '.' . $bittwo . '.' . $bitthree++);
		}
	}

	return \@list;
}


sub get_fwd_zonefile
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	my @list = $ld->get_zonefiles($host,$config);

	foreach my $file (@list) {
		my $bfile = basename($file);
		debug("Trying zonefile: $bfile");
		if (-e $bfile) {
			return $bfile;
		}
	}

	# Don't get here...
	croak('Can\'t find an appropriate forward zonefile');

}

sub add_reverse
{
	my $self = shift;
	my ($zonefile, $num, $host) = @_;
	my $ip = "$zonefile.$num";
	debug("Using $ip for $host->{'hostname'}");

	my $fh = get_fh($zonefile, '>>');

	print $fh "$num		PTR		"
		. "$host->{'hostname'}.\n";

	close($fh) || croak("close of $zonefile failed");

	show_diff($zonefile);
	commit_diff($zonefile);
}

sub add_forward
{
	my $self = shift;
	my ($zonefile, $ip, $host, $config) = @_;

	my $ld = $config->{'ld_ptr'};

	my $hostname = $ld->get_fwd_lhs($host,$config,$zonefile);

	checkout($zonefile);

	my $fh = get_fh($zonefile,'>>');

	print $fh "$hostname		A	$ip\n";

	close($fh) || croak("close of $zonefile failed");

	show_diff($zonefile);
	commit_diff($zonefile);

	checkin($zonefile,$host->{'hostname'},$config);

}

sub allocate_ip_and_reverse
{
	my $self = shift;
	my ($host,$config,$fwd_zonefile,$zonefile_list) = @_;
	my ($zonefile,$num,@lines,$freeips,$ip);

	# where to start/end searching in a zone
	my $start = $config->{'dns_start_search'};
	my $end = $config->{'dns_end_search'};

	foreach $zonefile (@{$zonefile_list}) {
		checkout("$zonefile");
	
		open(ZONE,"<$zonefile");
		@lines = <ZONE>;
		close(ZONE);
	
		#
		# FIXME:
		#    We assume that you're using un-fully-qualified
		#    entries for the LHS of your PTR records.
		#
		# FIXME:
		#    We also assume your zonefiles are split into /24s
		#    and named a.b.c which, while common, is a poor
		#    assumption to make.
		#
		foreach $num ($start..$end) {
			debug("trying $zonefile.$num");
			$freeips = grep(/^${num}\s+/,@lines);
			if ($freeips == 0) {
				my @out = $self->check_ip_in_fwd($fwd_zonefile,
					"$zonefile.$num",$host,$config);
				if (scalar(@out) != 0) {
					# this IP not available
					next;
				}
				$ip = "$zonefile.$num";
				if ($self->fpingable($ip)) {
					next;
				}
				$self->add_reverse($zonefile,$num,$host,$config);
				checkin("$zonefile",$host->{'hostname'},
						$config);
				return($ip);
			}
		}
		checkin("$zonefile",$host->{'hostname'},$config);
	}

	# we shouldn't get here
	croak('I was unable to find any free IPs!!');

}

#
# Search for an IP in a rev zone
# and return the NAME
#
sub check_ip_in_rev
{
	my $self = shift;
	my ($ip) = @_;

	my ($f1,$f2,$f3,$f4) = split(/\./,$ip);

	my $out = file_grep("$f1.$f2.$f3","^$f4" . '\s');

	if (!defined($out)) {
		# zonefile didn't exist, which technically means its not taken
		# but we don't want to then try and allocate it
		croak("While checking if $ip is in use, zonefile"
			. " $f1.$f2.$f3.$f4 didn't exist, please fix this");
	}

	#
	# There should only ever be ONE reverse entry
	# for a given IP. So we'll only remember the last one
	# we see, but we'll make sure we note if there is more than one
	# and bitch loudly.
	#
	my $num_valid_entries = 0;
	my $name = '';

	foreach my $line (@{$out}) {
		next if ($line =~ /^\s*[#;]/);

		$num_valid_entries++;

		($f1,$f2,$f3,$f4) = split(/\s+/,$line);
	
		if ($f2 eq 'PTR') {
			$name = $f3;
		} elsif ($f3 eq 'PTR') {
			$name = $f4;
		} else {
			croak('Can\'t parse reverse line!!');
		}
	}

	if ($num_valid_entries > 1) {
		croak("There is more than one reverse entry for $ip!");
	}

	return $name;
}

#
# Search for an IP in a fwd zone
# and return the NAME
#
sub check_ip_in_fwd
{
	my $self = shift;
	my ($zonefile,$ip,$host) = @_;

	my $out = file_grep($zonefile,'\b' . $ip . '\b');
	my @names = ();

	if (!defined($out)) {
		# zonefile didn't exist, which technically means its not taken
		# but we don't want to then try and allocate it
		croak("While checking if $ip is in use, zonefile"
			. " $zonefile didn't exist, please fix this");
	}

	foreach my $line (@{$out}) {
		next if ($line =~ /^\s*[#;]/);

		my ($f1,undef) = split(/\s+/,$line);
		push (@names,$f1);
	}

	return @names;
}

sub commit_dns
{
	my $self = shift;
	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run('DNS \'make\'');
	} else {
		if ($ENV{'ENABLE_VERBOSE'}) {
			verbose('DNS \'make\'');
		}
		my $output = `make 2>&1`;
		if ($? != 0) {
			mywarn("Make failed with exit status $?: $!");
			return 0;
		}
		debug("Output of 'make' on DNS server: $output");
	}

	return 1;
}

#
# Look for the host in forward
#
sub check_name_in_fwd
{
	my $self = shift;
	my ($host, $config, $fwd_zonefile) = @_;

	my $ld = $config->{'ld_ptr'};
	my $fwd = '';

	my $grepfor = $ld->get_fwd_lhs($host, $config, $fwd_zonefile);

	#
	# Bleck, we'll get warnings about comparing strings to ints
	# if we don't do the regex first. -1 means unsupported
	# in provision::local_decision, but valid returns for this
	# functions are strings.
	#
	# Perl should have a better way.
	#
	if ($grepfor =~ /^\d+$/ && $grepfor == -1) {
		croak('Building forward DNS entry not supported by'
			. ' local_decision plugin');
	}

	my $out = file_grep($fwd_zonefile, '^' . $grepfor . '\s');

	if (!defined($out)) {
		# zonefile didn't exist, which technically means its not taken
		# but we don't want to then try and allocate it
		croak("While checking if $host->{'hostname'} is in use,"
			. " zonefile $fwd_zonefile didn't exist, please fix"
			. ' this');
	}

	foreach my $line (@{$out}) {

		#
		# Here, we parse a standard bind-style zonefile. We ignore
		# lines starting with a pound or a semi-colon, and we look for
		# lines formatted like:
		#    foo	IN	A	a.b.c.d
		# or
		#    foo	A	a.b.c.d
		#
		# where "foo" can be an FQDN or a non-FQDN (we ask for
		# the valid LHS above).
		#

		next if ($line =~ /^\s*[#;]/);

		# Something's in forward, what is it...
		debug('Found something in forward zonefile,'
			. ' checking to see if it\'s what we want');
		my $ip = '';
		my ($f1,$f2,$f3,$f4) = split(/\s+/, $line);
		if ($f2 eq 'A') {
			$ip = $f3;
		} elsif ($f3 eq 'A') {
			$ip = $f4;
		} elsif ($f2 eq 'CNAME' || $f3 eq 'CNAME') {
			#
			# If the host is a CNAME then it can't
			# be anything else, reutnr undef let the
			# parent code explain and die however
			# it wants - we don't care about the rest
			# of the grep results
			#
			mywarn('host is a CNAME');
			return undef;
		}

		debug("Found $ip - checking it's a real ip");
		# Make sure we really have an IP
		if ($ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/) {
			$fwd = $ip;
			debug('Have forward already');
			last;
		} else {
			debug('This line didn\'t match IP regex...');
			$fwd = '';
		}
	}

	return $fwd;
}

sub check_name_in_rev
{
	my $self = shift;
	my ($host,$config,$rev_zonefile_list_ptr) = @_;

	my $ld = $config->{'ld_ptr'};
	my $rev = '';
	foreach my $zf (@{$rev_zonefile_list_ptr}) {
		my $grepfor = $ld->get_rev_rhs($host,$config,$zf);
		my $out = file_grep($zf,'\s' . $grepfor . '\s?$');

		if (!defined($out)) {
			# zonefile didn't exist, which technically means its not
			# taken but we don't want to then try and allocate it
			croak("While checking if $host->{'hostname'} is in"
				. " use, zonefile $zf didn't exist, please fix"
				. ' this');
		}
		foreach my $line (@{$out}) {
			next if ($line =~ /^\s*[#;]/);
			debug('Found something in reverse zonefile,'
                              . ' checking to see if it\'s what we want');
			my ($num,undef) = split(/\s+/,$line);
			my $ip = "$zf.$num";
			debug("Testing IP $ip");
			# Make sure we really have an IP
			if ($ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/) {
				$rev = $ip;
				debug('Reverse already done');
				return $rev;
			}
		}
	}

	return $rev;
}

sub cross_check
{
	my $self = shift;
	my ($host,$config,$fwd,$rev,$fwd_zonefile) = @_;
	my ($need_rev,$need_fwd) = (0,0);

	my $ld = $config->{'ld_ptr'};

	if ($fwd ne '' && $rev ne '') {
		#
		# If both are there, we need to make sure they match
		#
		if ($fwd ne $rev) {
			croak("DNS allocated for"
				. " $host->{'hostname'}, but forward"
				. " maps to $fwd, while rev claims $rev is the"
				. ' IP - please fix!');
		} else {
			return (0,0);
		}
	} elsif ($fwd ne '') {
		#
		# If only forward is allocated, see if that IP
		# is in reverse DNS
		#
		my $out = '';
		$out = $self->check_ip_in_rev($fwd);
		if ($out ne '') {
			if ($ld->match_rev($host,$config,$out)) {
				mywarn('DNS already allocated for '
                                     . " $host->{'hostname'} - but I didn't"
                                     . ' find it on first look - is something'
                                     . ' awry?');
				return (0,0);
			} else {
				debug("$out vs $host->{'hostname'}");
				croak('Forward and reverse DNS allocated for'
                                      . " $host->{'hostname'} but doesn't "
                                      . ' match');
			}
		} else {
			debug('Need to do reverse');
			$need_rev = 1;
		}
	} elsif ($rev ne '') {
		#
		# If only reverse is allocated, see if that IP
		# is in forward DNS
		#
		my @out = $self->check_ip_in_fwd($fwd_zonefile,$rev,$host);
		if (scalar(@out) != 0) {
			my $match = 0;
			foreach my $name (@out) {
				if ($ld->match_name_fwd($host,$config,
							$fwd_zonefile,$name)) {
					$match = 1;
					last;
				}
			}
			if ($match == 1) {
				mywarn('DNS already allocated for'
					. " $host->{'hostname'} - but I didn't"
					. ' find it on first look - is'
					. ' something awry?');
				return (0,0);
			} else {
				debug('Requested hostname is '
                                      . $host->{'hostname'} . ', but I'
                                      . ' found ' . join(' ',@out)
				      . ' in the reverse zone');
				croak('Forward and reverse DNS'
                                      . ' allocated for '
                                      . $host->{'hostname'} . ' but'
                                      . ' don\'t match');
			}
		} else {
			$need_fwd = 1;
		}
	} else {
		$need_fwd = 1;
		$need_rev = 1;
	}

	return($need_fwd,$need_rev);
}


sub get_dst_host
{
	my $self = shift;
	my ($host,$config,$ld) = @_;;

	return $config->{'dns_host'};
}

sub remove_name_from_fwd
{
	my $self = shift;
	my ($host,$zonefile,$config) = @_;

	#
	# Removal is a tricky process. Here's what we want to remove:
	#
	#  - Anything with the host on the left (A,CNAME,TXT)
	# 	(note we don't handle NS)
	#  - Any CNAMES _to_ us (as they'll be broken)
	#
	# And here's what we need to return to the caller:
	# 
	#  - The IP address the host pointed to, if it was an A record
	#
	# And finally, we want to warn upon removing any aliases pointing to
	# us.
	#

	my $ld = $config->{'ld_ptr'};

	# For saved IPs:
	my @ips;

	# Lets gather some basic info
	my $lhs = $ld->get_fwd_lhs($host,$config,$zonefile);

	#
	# If RHS is anything other than the FQDN,
	# we'll add the FQDN thing as something to match on.
	#
	unless ($lhs eq $host->{'hostname'} . '.') {
		my $fqdn = $host->{'hostname'};
		$lhs = "($fqdn(|.)|$lhs)";
	}

	checkout($zonefile);

	open(ZONE,"<$zonefile")
		|| croak("open of $zonefile failed");
	my @lines = <ZONE>;
	close(ZONE) || croak("close of $zonefile failed");

	# We can start by getting rid of all A records belong to the host -
	# but we want to save those IP addresses.
	my $regex = "^$lhs\\s+A";
	my @save = grep {/$regex/} @lines;
	my @newlines = grep {!/$regex/} @lines;
	@lines = @newlines;

	# Parse through @save and get the IPs
	foreach my $line (@save) {
		$line =~ /.*A\D+([\d\.]{7,15})/;
		push(@ips,$1);
	}

	@save = [];

	# If the host is a CNAME instead, we get rid of those as well.
	$regex = "^$lhs\\s+CNAME";
	@save = grep {/$regex/} @lines;
	@newlines = grep {!/$regex/} @lines;
	@lines = @newlines;

	# If there was an alias, we want to know that
	my $was_alias = 0;
	if (scalar(@save) > 0) {
		$was_alias = 1;
	}

	# Finally, we want to get rid of aliases pointing to the host. But, we
	# want to warn about them
	$regex = "^[^;#].*CNAME\\s+$lhs\$";
	@save = grep {/$regex/} @lines;
	@newlines = grep {!/$regex/} @lines;

	# Once again parse through @save, but this time, just print warnings
	# on them.
	foreach my $line (@save) {
		$line =~ /^(\S+)\s+CNAME/;
		mywarn("Removing $1, an alias to " . $host->{'hostname'});
	}

	my $fh = get_fh($zonefile,'>');

	print $fh @newlines;

	close($fh) || croak("Close of $zonefile failed");

	show_diff($zonefile);
	commit_diff($zonefile);

	checkin($zonefile,$host->{'hostname'},$config);

	return (\@ips,$was_alias);
}

sub remove_name_from_rev
{
	my $self = shift;
	my ($host,$rev_zone_list_ptr,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	# Lets gather some basic info
	my $rhs = $ld->get_rev_rhs($host,$config);

	#
	# If RHS is anything other than the FQDN,
	# we'll add the FQDN thing as something to match on.
	#
	unless ($rhs eq $host->{'hostname'} . '.') {
		my $fqdn = $host->{'hostname'};
		$rhs = "($fqdn(|.)|$rhs)\$";
	}
	

	my $num_removed = 0;

	foreach my $zonefile (@{$rev_zone_list_ptr}) {

		checkout($zonefile);

		open(ZONE,"<$zonefile")
			|| croak("open of $zonefile failed");
		my @lines = <ZONE>;
		close(ZONE) || croak("close of $zonefile failed");

		my $regex = "^.*PTR\\s+$rhs\$";
		my @save = grep {/$regex/} @lines;
		my @newlines = grep {!/$regex/} @lines;

		$num_removed += scalar(@save);

		my $fh = get_fh($zonefile, '>');

		print $fh @newlines;

		close($fh) || croak("Couldn't close $zonefile");

		show_diff($zonefile);
		commit_diff($zonefile);

		checkin($zonefile,$host->{'hostname'},$config);

	}

	return $num_removed;
}

sub remove_ip_from_rev
{
	my $self = shift;
	my ($host,$zonefile,$ip,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	my @ipbits = split(/\./,$ip);
	my $hostbit = $ipbits[-1];
	undef @ipbits;

	checkout($zonefile);
	open(ZONE,"<$zonefile")
		|| croak("open of $zonefile failed");
	my @lines = <ZONE>;
	close(ZONE) || croak("close of $zonefile failed");

	my $num_removed = 0;

	my $regex = "^$hostbit\\s.*PTR\\s+(\\S+)\$";
	my @newlines = ();
	foreach my $line (@lines) {
		if ($line =~ /$regex/) {
			my $dest = $1;
			unless ($ld->match_name_rev($host,$config,$dest)) {
				mywarn('While removing the matching reverse'
					. ' entry for ' . $host->{'hostname'}
					. ', I found it pointers to $dest,'
					. ' which I do not believe to be the'
					. ' same. As such, I\'m not removing'
					. ' it! Please clean up this'
					. ' reverse entry manually.');
			} else  {
				# This is the only case we don't add the entry
				# to the resulting file - in all other cases
				# we fall through to the push() below.
				$num_removed++;
				next;
			}
		}
		push(@newlines,$line);
	}

	my $fh = get_fh($zonefile, '>');

	print $fh @newlines;

	close($fh) || croak("Couldn't close $zonefile");

	show_diff($zonefile);
	commit_diff($zonefile);

	checkin($zonefile,$host->{'hostname'},$config);

	return $num_removed;
}


sub add_cname
{
	my $self = shift;
	my ($host, $zonefile, $config) = @_;

	my $ld = $config->{'ld_ptr'};
	my $hostname = $ld->get_fwd_lhs($host,$config,$zonefile);

	my $dst = $host->{'alias_dst'};
	if ($dst !~ /\.$/) {
		$dst .= '.';
	}

	checkout($zonefile);

	my $fh = get_fh($zonefile, '>>');

	print $fh "$hostname		CNAME	$dst\n";

	close($fh) || croak("close of $zonefile failed");

	show_diff($zonefile);
	commit_diff($zonefile);

	checkin($zonefile,$host->{'hostname'},$config);

	return 1;

}


sub fpingable
{
	my $self = shift;
	my $ip = shift;

	my $p = new Net::Ping();

	my $ret = $p->ping($ip,2);
	if (defined($ret) && $ret == 1) {
		return 1;
	} else {
		return 0;
	}
}


1;
