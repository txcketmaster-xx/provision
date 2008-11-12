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
# This is the provision package used by provision(8)
# and it's modules, provision_dns(8), provision_nfs(8), etc.
#
#

package provision::config;

use strict;
use warnings;
use YAML;
use Fcntl qw(:DEFAULT :flock);
use Carp;
use lib '/usr/lib';
use provision::util qw(:default);

use constant DEFAULT_LIBEXEC => '/usr/libexec';
use constant DEFAULT_DNS_HOST => 'ns1'
use constant DEFAULT_ZONE_PATH => '/chroot/named/var/named/pz';
use constant DEFAULT_START_IP => 10;
use constant DEFAULT_END_IP => 240;

use constant TOP_LEVEL_CONFIG_TREES => qw(range network_overlays zonepath
				dns_start_search dns_end_search devqa_re
				new_server local_decision default_plugins
				configfile filer_qtree_name filer_adm_host
				filer_username filer_path hostname_parse_data
				overlay_map vm_path vmlist_path dns_master);

my $VERSION = sprintf('%d',q$Revision$ =~ /: ([\d\.]+)/);

sub new
{
	my $package = shift;
	my ($config_file,$opts,$plugins) = @_;
	my $config = YAML::LoadFile($config_file);

	$config->{'configfile'} = $config_file;

	#
	# We pass in file config, it passes us a merged config.
	# We use the same variable since we no longer care about
	#  the file config.
	#
	$config = $package->_merge_config($config,$opts,$plugins);

	# most components of provision handle their own input
	# checking, however, everything uses ip range data,
	# so we'll check for it here.
	croak("Config file missing ip range data")
		if (!defined($config->{'range'}));

	return bless($config,$package);
}

sub _merge_config
{
	my $self = shift;
	my ($file,$opts,$plugins) = @_;

	my $config = $self->_get_defaults();

	#
	# Add the config file to the default options.
	#
	# Since we're not parsing our own config, people can throw all kinds
	# of junk in here, and that's not really what we want. So we look for
	# specific top-level trees we want.
	#
	# Local decision plugins have their own top-level tree for whatever
	# they may want.
	#

	foreach my $key (TOP_LEVEL_CONFIG_TREES) {
		if (exists($file->{$key})) {
			$config->{$key} = $file->{$key};
		}
	}

	#
	# Go through options, and add these to the config as well
	#
	if (exists($opts->{'debug'})) {
		$config->{'debug'} = 1;
	}
	if (exists($opts->{'dryrun'})) {
		$config->{'dryrun'} = 1;
	}
	if (exists($opts->{'verbose'})) {
		$config->{'verbose'} = 1;
	}
	if (exists($opts->{'warn'}) || exists($opts->{'quiet'})) {
		$config->{'nowarn'} = 1;
	}
	if (exists($opts->{'info'}) || exists($opts->{'quiet'})) {
		$config->{'noinfo'} = 1;
	}
	if (exists($opts->{'message'}) && $opts->{'message'} ne '') {
		$config->{'commit_msg'} = $opts->{'message'};
	}
	if (exists($opts->{'libexec'}) && $opts->{'libexec'} ne '') {
		$config->{'provision_path'} = $opts->{'libexec'};
	}
	if (exists($opts->{'user'}) && $opts->{'user'} ne '') {
		$config->{'user'} = $opts->{'user'};
	}
	if (exists($opts->{'override'}) && $opts->{'override'} ne '') {
		$config->{'fake_host'} = $opts->{'override'};
	}

	#
	# Add any plugin-specific options as well
	#
	my $plug_conf = {};
	foreach my $plugin (keys(%{$plugins})) {
		foreach my $option (keys(%{$plugins->{$plugin}->{'opts'}})) {
			if (exists($opts->{$option})) {
				$plug_conf->{$option} = $opts->{$option};
			}
		}
	}
	$config->{'plugin_opts'} = $plug_conf;

	return $config;
	
}

sub _get_defaults
{
	my $self = shift;
	
	my $config = {
		'debug' => 0,
		'dryrun' => 0,
		'nowarn' => 0,
		'noinfo' => 0,
		'verbose' => 0,
		'commit_msg' => '',
		'user' => 'root',
		'fake_host' => '',
		'provision_path' => DEFAULT_LIBEXEC,
		'zonepath' => DEFAULT_ZONE_PATH,
		'dns_start_search' => DEFAULT_START_IP,
		'dns_end_search' => DEFAULT_END_IP,
		'dns_master' => DEFAULT_DNS_HOST,
	};

	return $config;
};



1;
