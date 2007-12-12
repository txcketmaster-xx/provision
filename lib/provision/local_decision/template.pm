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
# Template local decision plugin
#

package provision::local_decision::TEMPLATE;

use strict;
use warnings;

use lib '/usr/lib';
use base qw(provision::local_decision);
use provision::util qw(:default);
our ($VERSION);


$VERSION = sprintf('%d.%03d',q$Revision$ =~ /: (\d+)\.(\d+)/);

sub get_filer
{
	my $self = shift;
	my ($host,$config) = @_;

	#
	# $host is a hash reference with the all the entries you defined
	# in your hostname_parse_data config, plus a "hostname" entry
	# with the full hostname.
	#
	# $config is a hash reference made up of the YAML in the config
	# file.
	#
	# If you're local_decision plugin would like additional config data,
	# you should put it under local_decision and your group, like this:
	#    local_decision:
	#      group1:
	#        something: else
	#      group2:
	#        - bar
	#        - baz
	#
	# Use this data to make your decision and return a filer.
	#

	#

	my $fls = 'fls1';

	# and return
	return $fls;

}	
	
sub get_vol
{
	my $self = shift;
	my ($host,$config) = @_;

	#
	# See note in get_filer
	#
	
	my $vol = 'vol1';

	return $vol;
}

1;
