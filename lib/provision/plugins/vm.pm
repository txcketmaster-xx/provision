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
# VM module of provisioning tool
#

package provision::plugins::vm;

use strict;
use warnings;
use Carp;
use File::Basename;
use lib '/usr/lib';
use provision::util qw(:default :plugin);

our $VERSION = sprintf('%d',q$Revision$ =~ /: ([\d\.]+)/);

use constant DEFAULT_NEW_SERVER => '/vrt/shared/bin/new_server';
use constant NOHUP => '/usr/bin/nohup';
use constant VMCMD => '/usr/bin/vmware-cmd';
use constant RM => '/bin/rm';
use constant OFF => 0;
use constant ON => 1;
use constant MAX_WAIT_COUNT => 5;

sub new
{
	my $package = shift;
	return bless({},$package);
}

sub local_opts
{
	shift;
	return {'vrt' => {
			'getopts' => '=s',
			'args' => '<vrt>',
			'help' => 'Specify the VRT to install VMs on.'
			},
		'vm-ram' => {
			'getopts' => '=s',
			'args' => '<ram>',
			'help' => 'Specify the amount of RAM to use, in MB.'
				. ' Optional.',
			},
		'vm-os' => {
			'getopts' => '=s',
			'args' => '<os>',
			'help' => 'Specify the OS to use (3TM, 4TM, etc.).'
				. ' Optional.',
			},
		};
}

sub get_dst_host
{
	my $self = shift;
	my ($host,$config,$ld) = @_;

	if (!exists($config->{'plugin_opts'}->{'vrt'})) {
		mywarn("No VRT passed in. If you want to allocate a VM, you must"
                     . " specify a VRT!");
		return undef;
	}
	return $config->{'plugin_opts'}->{'vrt'};
}

sub run
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};
        unless ($ld->check_do_plugin($host,$config,'vm')) {
                return 1;
        }

	if ($host->{'action'} == provision::data::ACTION_ADD) {
		return $self->allocate($host,$config);
	} elsif ($host->{'action'} == provision::data::ACTION_REMOVE) {
		return $self->deallocate($host,$config);
	} elsif ($host->{'action'} == provision::data::ACTION_ALIAS) {
		return $self->alias($host,$config);
	} else {
		mywarn("This action is not something I support");
		return 1;
	}

	return 0;
}

sub allocate
{
	my $self = shift;
	my ($host,$config) = @_;

	my ($in_vmlist, $in_vmdir) = (0,0);

	my $new_server = DEFAULT_NEW_SERVER;
	if (exists($config->{'new_server'})) {
		$new_server = $config->{'new_server'};
	}
	#
	# Determine how much, if any has already been done
	#

	my $ld = $config->{'ld_ptr'};

	my $vm_path = $ld->get_vm_path($host,$config);
	my $vmlist_path = $ld->get_vmlist_path($host,$config);

	# This pattern anchors at the beginning, but not at the end so we can
	# catch a variety of OS's, etc... this is enough to definitively match
	my $pattern = "^config \"$vm_path";
	if ( -r $vmlist_path ) {
		my $out = file_grep($vmlist_path,$pattern);
		if (!defined($out)) {
			croak('file_grep doesn\'t think ' . $vmlist_path
				. ' exists, but it does. Confused and bailing'
				. ' out!');
		}
		if (scalar(@{$out}) != 0) {
			$in_vmlist = 1;
		}
	} else {
		$in_vmlist = 0;
	}

	if (-d $vmlist_path . '/' . $host->{'hostname'}) {
		$in_vmdir = 1;
	}

	#
	# Report things that have already been done
	#
	if ($in_vmlist && $in_vmdir) {
		info('VM: VM already allocated for '
			. $host->{'hostname'});
		return 1;
	} elsif ($in_vmlist) {
		mywarn('VM: VM is in vmlist but not created!');
		return 0;
	} elsif ($in_vmdir) {
		mywarn('VM: VM is created but not in vmlist!');
		return 0;
	}


	#
	# If we get here, we can proceed
	#

	my $retval = $self->run_new_server($new_server,$host->{'hostname'},
			$config);

	if ($retval) {
		info("VM: VM building for $host->{'hostname'} - not waiting"
                     . ' around for it.');
	} else {
		info("VM: Failed to build VM for $host->{'hostname'}");
	}

	return $retval;
}

sub deallocate
{
	my $self = shift;
	my ($host,$config) = @_;

	unless($host->{'v3'}) {
		debug("VM: Non-v3 hosts don't need deprovisioning from vm.pm."
                      . " Doing nothing.");
		info("VM: No deallocation needed");
		return 1;
	}

	my $cmd = VMCMD . " -l";
	my $list = `$cmd`;
	chomp($list);

	my @list = split(/\s/,$list);
	debug("Got list from vmware-cmd: " . join(' ',@list));

	my @cfgs = grep(/$host->{'hostname'}/,@list);

	if (scalar(@cfgs) == 0) {
		info("VM: No deallocation needed");
		return 1;
	} elsif (scalar(@cfgs) != 1) {
		mywarn("VM: Found more than one matching VM! I'm confused"
			. " bailing out.");
		return 0;
	}

	my $cfg = $cfgs[0];

	debug("cfg is $cfg");

	my $st = $self->getstate($cfg);
	my $confdir = dirname($cfg);

	my $out = '';
	$cmd = VMCMD . " $cfg stop";
	if ($st == ON) {
		debug("Stopping $cfg");
		if ($ENV{'ENABLE_DRYRUN'}) {
			dry_run($cmd);
		} else {
			if ($ENV{'ENABLE_VERBOSE'}) {
				verbose($cmd);
			}
			$out .= `$cmd`;
		}
	}

	my $count = 0;
	if (!$ENV{'ENABLE_DRYRUN'}) {
		while ($st == ON) {
			debug("Waiting for STOP (count == $count)");
			unless ($count < MAX_WAIT_COUNT) {
				last;
			}
			sleep 3;
			$st = $self->getstate($cfg);
			$count++;
		}
	}

	if ($st != OFF && !$ENV{'ENABLE_DRYRUN'}) {
		mywarn("Failed to stop the VM. Not removing it.");
		return 0;
	}
	
	debug("Unregistering $cfg");
	$cmd = VMCMD . " -s unregister $cfg";
	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
	} else {
		if ($ENV{'ENABLE_VERBOSE'}) {
			verbose($cmd);
		}
		$out .= `$cmd`;
	}

	debug("Removing $cfg");
	$cmd = RM . " -rf $confdir";
	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	} else {
		if ($ENV{'ENABLE_VERBOSE'}) {
			verbose($cmd);
		}
		$out .= `$cmd`;
	}

	info("Deallocated " . $host->{'hostname'});
	return 1;
}

sub alias
{
	my $self = shift;

	# No VM work for an alias

	return 1;
}

sub run_new_server
{
	my $self = shift;
	my ($new_server,$host,$config) = @_;

	# Since we'll be running new_server in nohup, backgrounded,
	# and not waiting for it to finish, we'll get no exit status,
	# so we should at least make sure the path we're using is valid.
	unless (-x $new_server) {
		mywarn("VM: $new_server doesn't exist or is not executable\n");
		return 0;
	}

	# First, figure out if our optional arguments are present,
	# and if so, if they're valid.
	my $args = '';
	if (exists($config->{'plugin_opts'}->{'vm-ram'})) {
		if ($config->{'plugin_opts'}->{'vm-ram'} =~ /^\d+$/) {
			$args .= ' -m ' . $config->{'plugin_opts'}->{'vm-ram'};
		} else {
			mywarn('VM: RAM amount specified was not a number! '
                             . ' Ignoring.');
		}
	}
	if (exists($config->{'plugin_opts'}->{'vm-os'})) {
		$args .= ' -d ' . $config->{'plugin_opts'}->{'vm-os'};
	}

	#
	# Building a VM can take 10 or more minutes, we're not going
	# to wait around for each time. In the near future, new_server
	# will send you an email when it's done, as well as send you errors
	# if there were any.
	# 
	# Therefore, we redirect stdout and stderr, and nohup and background
	# it, and move on. Though we explain this to the user.
	#
	my $cmd = NOHUP
		. " $new_server -h $host $args >/dev/null 2>/dev/null &";
	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}
	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}
	debug("Running $cmd");
	`$cmd`;

	return 1;
}

sub getstate
{
	my $self = shift;
	my ($cfg) = @_;

	my $cmd = VMCMD . " $cfg getstate";
	my $out = `$cmd`;
	chomp($out);

	my (undef,$state,undef) = split(' \= ',$out);
	if ($state eq "off") {
		return OFF;
	} else {
		return ON;
	}
}

1;
