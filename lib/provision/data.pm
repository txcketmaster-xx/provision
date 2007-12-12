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
# This is the provision config package.
#

package provision::data;

our($DEBUG,$WARN,$VERSION);
use strict;
use warnings;
use YAML;
use Carp;
use lib '/usr/lib';
use provision::util qw(:default :provision);

use constant ACTION_ADD => 0;
use constant ACTION_REMOVE => 1;
use constant ACTION_ALIAS => 2;

$VERSION = sprintf('%d.%03d',q$Revision$ =~ /: (\d+)\.(\d+)/);

sub new
{
	my $package = shift;
	my $self = {};

	return bless($self,$package);
}


##################################
#
# parse_hostname
#
# Takes in a ptr to a hash, and a hostname
#
# Parses hostname into the hash
#
# Returns:
#       0 bad
#       1 good
#
sub add_host
{
	my $self = shift;
	my ($hostname, $config, $bad, $good) = @_;

	debug("Adding $hostname");

	my $host = {};

	#
	# Our default action is to add
	#
	$host->{'action'} = ACTION_ADD;

	if ($hostname =~ /^\+/) {
		$host->{'action'} = ACTION_ADD;
		$hostname =~ s/^\+//;
	} elsif ($hostname =~ /^~/) {
		$host->{'action'} = ACTION_REMOVE;
		$hostname =~ s/^~//;
	} elsif ($hostname =~ /.*=.*/) {
		$host->{'action'} = ACTION_ALIAS;
		my ($src,$dst) = split('=',$hostname,2);
		$hostname = $src;
		$host->{'alias_dst'} = $dst;
	}

	$host->{'hostname'} = $hostname;

	my $parsers = $config->{'hostname_parse_data'};

	unless (defined($parsers)) {
		croak('No hostname_parse_data specified in config file.');
	}

	# Yes, "indexes" is also a valid plural, according to Webster,
	# it's just as valid as "indices", and much easier for me to type
	my ($re,$indexes);
	foreach my $entry (@{$parsers}) {
		$re = $entry->{'re'};
		debug("trying RE $re");
		if ($hostname =~ m/^$re$/) {
			debug('Success with RE!');
			$indexes = $entry->{'indexes'};
			if (exists($entry->{'skip_plugins'})) {
				$host->{'skip_plugins'} =
					$entry->{'skip_plugins'};
			}
			last;
		}
	}

	unless (ref($indexes) eq 'HASH') {
		croak('Failed to parse hostname with configured hostname_re');
	}

	# We re-run the match to re-populate $1 - $n for the user
	$hostname =~ m/^$re$/;
	foreach my $key (keys(%{$indexes})) {
		debug("populating $key");
		my $val = eval "$indexes->{$key}";
		$host->{$key} = $val;
	}

	#
	# This is the EARLIEST we can possibly get an LD, and we need one
	# so that people can add their own host information
	#
	my $ld;
	if (defined($bad) && defined($good)) {
		$ld = find_ld($host, $bad, $good);
	} else {
		$ld = find_ld($host);
	}

	my $ret = $ld->post_parse_setup($host);

	if ($ret == -1) {
		debug('User had no post_parse_setup to do');
	} elsif ($ret != 1) {
		croak('Users\' post_parse_setup failed!');
	}

	$self->map_overlays($host, $config);

	# Before we use $hostname again, get any changes from the user
	$hostname = $host->{'hostname'};

	# And add it to the object
	$self->{$hostname} = $host;

	return ($hostname, $ld);
}

sub map_overlays
{
	my $self = shift;
	my ($host, $config) = @_;

	unless (exists($config->{'overlay_map'})) {
		return 1;
	}

	my $group = $host->{'group'};

	if (exists($config->{'overlay_map'}->{$group})) {
		my $overlays = $config->{'overlay_map'}->{$group};
		foreach my $entry (keys(%{$overlays})) {
			my @regexes = keys(%{$overlays->{$entry}});
			foreach my $re (@regexes) {
				if (exists($host->{$entry}) &&
				    $host->{$entry} =~ /^$re$/) {
					debug('Adding overlay mapping of'
						. " $entry: "
						. $overlays->{$entry}->{$re});
					$host->{"overlay_$entry"} = 
						$overlays->{$entry}->{$re};
					last;
				}
			}
		}
	}

	return 1;
}

1;
