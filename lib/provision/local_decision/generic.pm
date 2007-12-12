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
# Generic local decision plugin
#
# This attempts to allow people to put their filer/volume info into a
# configuration file rather than have to write a plugin.
#

package provision::local_decision::generic;

use strict;
use warnings;

use Carp;
use lib '/usr/lib';
use base qw(provision::local_decision);
use provision::util qw(:default);
our ($VERSION);

$VERSION = sprintf('%d.%03d',q$Revision$ =~ /: (\d+)\.(\d+)/);

sub descend_level
{
	my $self = shift;
	my ($host,$c,$obj) = @_;

	my $result = undef;
	if (exists($c->{$obj})) {
		debug("Found a valid $obj: $c->{$obj}");
		$result = $c->{$obj};
	}

	#
	# This is some ugly stuff. Since we have no idea what you're going
	# to put in the 'local_decision' section of your config file,
	# we'll try to grab an entry that looks like what we want, as far
	# deep into the tree as possible (i.e. most specific).
	#
	# Unfortunately, we can't definitively say what parts of the tree
	# apply to us, since (a) we won't have made three and (b) the point
	# of this LD Plugin is to provide something that at least mostly
	# works for people who can't or don't want to write their own. That
	# means no callbacks to "does this match" that we expect the user
	# to write... we *are* the thing that'd get called back.
	#
	# So, at each level, we just see if it matches any portion of the
	# host structure. This is obviously error prone, but it's a
	# best-guess that will get provision up and running for basic setups.
	#
	foreach my $e (keys(%$c)) {
		next if ($e eq $obj);
		my $descend = 0;
		foreach my $k (keys(%$host)) {
			#
			# Only descned into things that look like
			# they're relevant to our host
			#
			debug("comparing $e to host $k ($host->{$k}");
			if ($e eq $host->{$k}) {
				$descend = 1;
				last;
			}
		}
		unless ($descend) {
			debug("skipping $e\n");
			next;
		}

		debug("descending into $e");
		my $out = $self->descend_level($host,$c->{$e},$obj);
		if (defined($out)) {
			$result = $out;
		}
	}

	return $result;
}
	

sub descend_specifics
{
	my $self = shift;
	my ($host,$config,$obj) = @_;

	my $c = $config->{'local_decision'}->{$host->{'group'}};

	#
	# We start at the most specific, and fall back to the least
	# specific.
	#

	return $self->descend_level($host,$c,$obj);

}

sub get_filer
{
	my $self = shift;
	my ($host,$config) = @_;

	my $fls = $self->descend_specifics($host,$config,'filer');
	unless (defined($fls)) {
		croak('Couldn\'t determine filer from config file');
	}
	return $fls;
}	
	
sub get_vol
{
	my $self = shift;
	my ($host,$config) = @_;

	my $vol = $self->descend_specifics($host,$config,'vol');
	unless (defined($vol)) {
		croak('Couldn\'t determine filer from config file');
	}
	return $vol;
}


1;
