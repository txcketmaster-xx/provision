# -*- mode: perl; -*-
# vim:textwidth=78:

# $Id: local_decision.pm,v 1.9 2007/09/14 19:00:31 phil Exp $

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
# Super class for local_decision plugins
#
# Functions that make sense to implement abstractly are here, anything
# else returns -1 (not implemented)
#
# There is a "generic" plugin that will attempt to fill in the rest,
# as best it can, but shops are likely to want to override those
# anyway.
#

package provision::local_decision;

use strict;
use warnings;

use Scalar::Util qw(reftype);
use lib '/usr/lib';
use provision::util qw(:default);
our ($VERSION);

$VERSION = sprintf('%d.%03d',q$Revision: 1.9 $ =~ /: (\d+)\.(\d+)/);

#
# You should never have to bother with this.
#
sub new
{       
	my $package = shift;
	return bless({},$package);
}

#
# BEGIN NON-PLUGIN SECTION (or at least not specific to a particular plugin)
#

#
# Populate extra data about the hostname in addition to what the regex gives
# us.
#
sub post_parse_setup
{
	my $self = shift;
	my ($host,$config) = @_;

	return -1;
}
 
#
# We're not going to assume anything here, so they'll all go in one group.
#
# You should write you're own - if you group by destionation, it's much
# faster.
#
sub sort_hostlist_by_dst
{
	my $self = shift;
	my @hostlist = @_;

	my %hash;
	$hash{'all'} = \@hostlist;
	
	return \%hash;

}

#
# Recursive sub to descend the "ranges" section of the config.
# This is a depth-first first-match algorithm. We descend the range
# hash *only* descending sections that match some part of our hostname.
#
# We'll take the most-specific (depth-first), match, but if we hit a leaf
# node that matches in our first descended-branch, we will cease checking
# other branches.
#
sub _descend_range
{
	my $self = shift;
	my ($range,$host) = @_;

	#
	# reftype can return undef, so we need to make sure it's defined
	# before we compare it. Since we only want to continue if it's a
	# hash, we check to see if it's undefined *or* not a hash. Either
	# way, we stop.
	#
	my $r = reftype($range);
	if (!defined($r) || $r ne 'HASH') {
		return $range;
	}

	foreach my $k (keys(%{$range})) {
		foreach my $j (keys(%{$host})) {
			# We know the key exists, but we need to make sure
			# the value is not undef.
			next unless (defined($host->{$j}));
			if ($k eq $host->{$j}) {
				return $self->_descend_range($range->{$k},
								$host);
			}
		}
	}
}

sub get_range
{
	my $self = shift;
	my ($host,$config) = @_;

	my $range = $self->_descend_range($config->{'range'},$host);
	return $range;
}

#
# A hook to allow us to skip certain plugins for certain hosts
#
sub check_do_plugin
{
	my $self = shift;
	my ($host, $config, $plugin) = @_;

	return 1;
}

#
# END NON-PLUGIN SECTION
#

#
# BEGIN FILER SECTION
#    You should only need these if you use the filer plugin.
#

#
# Return a filer name. Can be fqdn, or some short name. The name will mostly
# just be used to pass to other LD things to build paths, names, etc.
#
sub get_filer
{
	my $self = shift;
	my ($host,$config) = @_;

	return -1;
}	
	
#
# Same as aboce, but for volumes
#
sub get_vol
{
	my $self = shift;
	my ($host,$config) = @_;

	return -1;
}

#
# Return the hostname that's an "admin host" for a given filer...
#
# By default, we just interpolate a templated value from the config file.
# If you need something more complicated, override it.
#
sub get_filer_adm_host
{
	my $self = shift;
	my ($host,$config) = @_;

	my $hostname = $config->{'filer_adm_host'};

	foreach my $key (keys(%{$host})) {
		$hostname =~ s/__${key}__/$host->{$key}/g;
	}

	if ($hostname =~ /__\w+__/) {
		debug("Still templatized stuff laying around: $hostname");
		# We didn't have enough information
		return undef;
	}

	return $hostname;
}

#
# Filers are generally mounted at the per-volume level on their admin hosts.
# This is where we expect to find stuff like the etc mount.
#
sub get_filer_adm_path
{
	my $self = shift;
	my ($host,$config,$fls) = @_;

	my $path = $config->{'filer_path'};

	$path =~ s/__filer__/$fls/;
	$path =~ s/__vol__/vol0/;
	$path .= '/etc';

	return $path;
}

#
# This function breaks a hostname up and creates a list of possible
# zonefile names, most specific to least specific. So with a hostname of:
#    foo.bar.baz.bing.bof
# you'll get:
#    bar.baz.bing.bof
#        baz.bing.bof
#            bing.bof
#                 bof
#
# They will of course be prepended with the zonefile path. This should be
# generic enough to suit most people's needs.
#
sub get_zonefiles
{
	my $self = shift;
	my ($host,$config) = @_;

	my @files = ();
	my $path = $config->{'zonepath'};

	my @bits = split('\.',$host->{'hostname'});

	for (my $i = 0; $i < scalar(@bits); $i++) {
		my $name = '';
		for (my $n = scalar(@bits)-1; $n > $i; $n--) {
			$name = $bits[$n] . '.'. $name;
		}
		chop($name);
		push(@files,"$path/$name");
	}

	return @files;
}

#
# We assume here you can express qtree names as a function of information
# about the host. If not, override this function.
#
sub get_qtree_name
{
	my $self = shift;
	my ($host,$config) = @_;

	my $name = $config->{'filer_qtree_name'};

	foreach my $key (keys(%{$host})) {
		next unless (defined($host->{$key}));
		$name =~ s/\_\_$key\_\_/$host->{$key}/g;
	}

	return $name;
}

#
# Much like "adm_path", but just for a volume
#
sub get_vol_mount_point
{
	my $self = shift;
	my ($host,$config,$fls,$vol) = @_;

	my $mp = $config->{'filer_path'};

	$mp =~ s/__filer__/$fls/g;
	$mp =~ s/__vol__/$vol/g;

	return $mp;
}

#
# What does the actual export value for a host look like?
#
sub get_export_rhs
{
	my $self = shift;
	my ($host,$config) = @_;

	my $rhs = '-sec=sys,rw=' . $host->{'hostname'};
	return $rhs;
}

#
# Generally people will want some directories made or permissions changed
# in a qtree once it's created. This is the callback for that. Not required.
#
sub post_qtree_setup
{
	my $self = shift;
	my ($host,$config,$dir) = @_;

	return -1;
}

#
# END FILER SECTION
#

#
# BEGIN DNS SECTION
#    callbacks for the dns plugin.
#

#
# This is something most people will need to override. We assume the most
# basic default: an FQDN
#
sub get_fwd_lhs
{
	my $self = shift;
	my ($host,$config,$fwd_zonefile) = @_;

	return $host->{'hostname'} . '.';

}

#
# You usually must have an FQDN on the RHS of reverse zones.
#
sub get_rev_rhs
{
	my $self = shift;
	my ($host,$config,$rev_zonefile) = @_;

	# We don't use "rev_zonefile" here, but someone may want it
	# if they make their own get_rev_rhs

	return $host->{'hostname'} . '.';
}

#
# When searching to see if a host is already allocated, different zonefiles
# may have different levels of host-qualification. So we let
# the user tell is what matches and what doesn't.
#
# The following is an educated guess, at best. Overriding is highly
# recommended.
#
sub match_name_fwd
{
	my $self = shift;
	my ($host,$config,$fwd_zonefile,$entry) = @_;

	# This is a POOR match function. You SHOUD WRITE YOUR OWN
	if ($entry =~ /^$host->{'hostname'}\./) {
		return 1;
	} else {
		return 0;
	}
}

# Same as above, but for reverse zonefiles. In this case the default
# is more sane.
sub match_name_rev
{
	my $self = shift;
	my ($host,$config,$entry) = @_;

	if ($entry =~ /^$host->{'hostname'}\./) {
		return 1;
	} else {
		return 0;
	}
}

#
# END DNS SECTION
#

#
# BEGIN VM SECTION
#

#
# Templatized config, but you can make it more complicated with a function.
#
sub get_vm_path
{
	my $self = shift;
	my ($host,$config) = @_;

	my $name = $config->{'vm_path'};

	foreach my $key (keys(%{$host})) {
		next unless (defined($host->{$key}));
		$name =~ s/\_\_$key\_\_/$host->{$key}/g;
	}

	return $name;
}

#
# A path to where a vmlist is on a VMware host.
#
sub get_vmlist_path
{
	my $self = shift;
	my ($host,$config) = @_;

	return $config->{'vmlist_path'};
}

#
# END VM SECTION
#


1;
