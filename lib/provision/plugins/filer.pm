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
# This is the filer plugin for the provision tool.
#

package provision::plugins::filer;

use strict;
use warnings;
use Carp;
use lib '/usr/lib';
use provision::util qw(:default :plugin);
use provision::data;

our $RSH = '/usr/bin/rsh';
our $RM = '/bin/rm';
our $VERSION = sprintf('%d',q$Revision$ =~ /: ([\d\.]+)/);

use constant DEFAULT_OPS_HOST => 'ops1.sys.adm2.websys.tmcs';
use constant DEFAULT_QUOTA => '5G';

use constant QUOTA_UPDATE_NONE => 0;
use constant QUOTA_UPDATE_OFFON => 1;
use constant QUOTA_UPDATE_RESIZE => 2;
use constant EXPORT_UPDATE_NONE=> 0;
use constant EXPORT_UPDATE_NEEDED => 1;
use constant DIR_UPDATE_NONE => 0;
use constant DIR_UPDATE_NEEDED => 1;

sub new
{
	my $package = shift;
	return bless({},$package);
}

sub local_opts
{
	shift;
	my $opts = {'filer' =>
			{
			'getopts' => '=s',
			'args' => 'fls<n>:vol<n>',
			'help' => <<EOF
Override provision's internal logic for determining
\t\twhere to provision qtrees. For example, if you specify
\t\t--filer fls2:vol2 all hosts being provisioned will be
\t\tput on fls2:/vol/vol2 on their respective filers.
EOF
			},
		   };
	return $opts;
}

sub run
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	unless ($ld->check_do_plugin($host,$config,'filer')) {
		return 1;
	}

	#
	# First, lets make sure our local_decision plugin is good
	#

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

##################################
#
# allocate_qtrees
#
# Takes in ptr to the host hash and the hostname itself
#
# Returns:
#   1 - done
#  -1 - already exists
#
# For all real errors, it dies - that should probably change at some point
#
sub allocate
{

	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};
	my ($fls,$vol,$qtree) = $self->get_fls_vol_qtree($host,$config);

	my $mp = $ld->get_vol_mount_point($host,$config,$fls,$vol);
	my $q_path = $mp . "/$qtree";
	my $adm_path = $ld->get_filer_adm_path($host,$config,$fls);
	
	debug("changing dir to $adm_path");
	chdir($adm_path);

	my ($need_q_resize, $need_export);
	$need_export = $self->update_exports($host,$config,$fls,$vol,$qtree);
	$need_q_resize = $self->update_quotas($host,$config,$fls,$vol,$qtree);

	unless ( -d "$q_path" ) {
		$self->create_qtree($fls,$vol,$qtree)
	}

	if ($need_export == EXPORT_UPDATE_NEEDED) {
		$self->export($fls,$vol,$qtree);
	} elsif ($need_export == EXPORT_UPDATE_NONE) {
		debug('no export needed');
	} else {
		croak('Uh-oh, I don\'t know what to do about exports!');
	}
		
	if ($need_q_resize == QUOTA_UPDATE_OFFON) {
		$self->reset_quotas($fls,$vol);
	} elsif ($need_q_resize == QUOTA_UPDATE_RESIZE) {
		$self->resize_quotas($fls,$vol);
	} elsif ($need_q_resize == QUOTA_UPDATE_NONE) {
		debug("No quota resize needed");
	} else {
		croak('Uh-oh, I don\'t know what to do about quotas!');
	}

	# post-setup callback
	my $needed_dir = $ld->post_qtree_setup($host,$config,$q_path);

	#
	# All plugins should print a final status message
	#
	if ($need_export == EXPORT_UPDATE_NONE
				&& $need_q_resize == QUOTA_UPDATE_NONE
				&& $needed_dir == DIR_UPDATE_NONE) {
		info('FILER: Filer space already allocated for '
			. $host->{'hostname'});
	} else {
		info("FILER: Allocated $qtree on $fls:$vol for "
			. $host->{'hostname'});
	}
	return 1;
}

sub deallocate
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};


	my ($fls,$vol,$qtree) = $self->get_fls_vol_qtree($host,$config);

	my $mp = $ld->get_vol_mount_point($host,$config,$fls,$vol);
	my $q_path = $mp . "/$qtree";
	my $adm_path = $ld->get_filer_adm_path($host,$config,$fls);

	debug("changing dir to $adm_path");
	chdir($adm_path);


	unless (-d $q_path) {
		debug("$q_path isn't a directory");
		info('Filer: Nothing to deallocate');
		return 1;
	}

	my $remove_qtree = $ld->remove_qtree_check($host,$config,$q_path);
	
	if ($remove_qtree == 1) {
		#
		# If this is the last host of it's kind, we're decomissioning
		# a class, woo! So here's what we do:
		#   1. Unexport it.
		#   2. Remove the line from exports
		#   3. Remove the line from quotas
		#   4. rm -rf the qtree
		#
	
		$self->unexport($fls,$vol,$qtree);
	
		$self->remove_exports_quotas($host,$fls,$vol,$qtree,$config);
			
		$self->remove_qtree($fls,$vol,$qtree);
	}

	info('Filer: Deallocated ' . $host->{'hostname'});
	return 1;

}

sub alias
{
	my $self = shift;

	# Aliasing doesn't require the filer

	return 1;
}

sub update_exports
{
	my $self = shift;
	my ($host,$config,$fls,$vol,$qtree) = @_;
	my ($f1, $f2, @lines, $need_export);

	my $ld = $config->{'ld_ptr'};
	my $range = $ld->get_range($host,$config);
	my $rhs = $ld->get_export_rhs($host,$config);

	my $found = 0;

	checkout('exports') unless ($ENV{'ENABLE_DRYRUN'});
	
	open(EXPORTS,'<exports')
		|| die("open of exports failed");
	@lines = <EXPORTS>;
	close(EXPORTS);

	foreach (0..$#lines) {
		($f1,$f2) = split(/\s+/,$lines[$_]);
		if ($f1 eq "/vol/$vol/$qtree") {
			$found = 1;	
			if ($f2 eq $rhs) {
				debug('Export already done');
				$need_export = EXPORT_UPDATE_NONE;
				last;
			} else {
				mywarn('Changing export to new format');
				$lines[$_] = "/vol/$vol/$qtree\t$rhs\n";
				$need_export = EXPORT_UPDATE_NEEDED;
				last;
			}
		}
	}

	if ($found == 0) {
		push(@lines,"/vol/$vol/$qtree\t$rhs\n");
		$need_export = EXPORT_UPDATE_NEEDED;
	}

	my $file = 'exports';
	my $fh = get_fh($file,'>');

	debug("Adding export");
	foreach (@lines) {
		print $fh "$_";
	}
	close($fh);

	show_diff($file);
	commit_diff($file);

	checkin($file,$host->{'hostname'},$config)
		unless ($ENV{'ENABLE_DRYRUN'});

	return $need_export;
}

sub update_quotas
{
	my $self = shift;
	my ($host,$config,$fls,$vol,$qtree) = @_;
	my ($found,$need_q_resize) = (0,undef);

	checkout('quotas')
		unless ($ENV{'ENABLE_DRYRUN'});

	open(QUOTAS,'quotas');
	foreach (<QUOTAS>) {
		if ($_ =~ m~^/vol/$vol/$qtree~) {
			$found = 1;
			$need_q_resize = QUOTA_UPDATE_NONE;
			debug('Quota already done');
			last;
		}
	}
	close(QUOTAS);

	my $q = $config->{'default_quota'};
	unless (defined($q) && $q ne '') {
		$q = DEFAULT_QUOTA;
	}

	if ($found == 0) {
		my $line = "/vol/$vol/$qtree\ttree\t$q";

		my $file = 'quotas';
		my $fh = get_fh($file, '>>');

		print $fh "$line\n";
		close($fh);
		$need_q_resize = QUOTA_UPDATE_OFFON;
		show_diff($file);
		commit_diff($file);
	}

	checkin('quotas',$host->{'hostname'},$config)
		unless ($ENV{'ENABLE_DRYRUN'});

	#
	# If quotas aren't on, we don't want to turn them on.
	# However, we wait until now to test, because we want to add
	# a sane default to quotas anyway incase quotas are only off
	# temporarily.
	unless ($self->are_quotas_on($fls,$vol)) {
		return QUOTA_UPDATE_NONE;
	}

	return $need_q_resize;

}

sub create_qtree
{
	my $self = shift;
	my ($fls,$vol,$qtree) = @_;
	
	my $cmd = "$RSH $fls \"qtree create /vol/$vol/$qtree\" 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}

	my $output = `$cmd`;
	if ($? != 0) {
		mywarn("Creating qtree failed with exit status $?: $!");
	}
	debug("output of qtree create was: $output");
	return 1;
}

sub export
{
	my $self = shift;
	my ($fls,$vol,$qtree) = @_;

	my $cmd = "$RSH $fls \"exportfs -v /vol/$vol/$qtree\" 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}

	debug("Running on $fls");
	my $output = `$cmd`;
	if ($? != 0) {
		mywarn("Doing export failed with exit status $?:"
			. " $!");
	}
	debug("output of exportfs was: $output");
	return 1;
}

sub unexport
{
	my $self = shift;
	my ($fls,$vol,$qtree) = @_;

	my $cmd = "$RSH $fls \"exportfs -v -u /vol/$vol/$qtree\" 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}

	debug("Running on $fls");
	my $output = `$cmd`;
	if ($? != 0) {
		mywarn("Doing export failed with exit status $?: $!");
	}
	debug("output of exportfs was: $output");
	return 1;
}

sub resize_quotas
{
	my $self = shift;
	my ($prob,$fls,$vol) = @_;

	my $cmd = "$RSH $fls \"quota resize $vol\" 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}

	debug("Running  on $fls");
	my $output = `$cmd`;
	if ($? != 0) {
		mywarn("Resizing quotas failed with exit status $?: $!");
	}
	debug("output of quota resize was: $output");
	return 1;
}

sub reset_quotas
{
	my $self = shift;
	my ($fls,$vol) = @_;

	my $cmd1 = "$RSH $fls \"quota off $vol\" 2>&1";
	my $cmd2 = "$RSH $fls \"quota on $vol\" 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd1);
		dry_run($cmd2);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd1);
		verbose($cmd2);
	}

	my $output;

	debug("Running on $fls");
	$output = `$RSH $fls "quota off $vol" 2>&1`;
	if ($? != 0) {
		mywarn("Turning quotas off failed with exit status $?: $!");
	}

	debug("Running \"quota on $vol\" on $fls");
	$output .= `$RSH $fls "quota on $vol" 2>&1`;
	if ($? != 0) {
		mywarn("Turning quotas on failed with exit status $?: $!");
	}

	debug("output of quota reset was: $output");
}

sub get_dst_host
{
	my $self = shift;
	my ($host, $config, $ld) = @_;

	return $ld->get_filer_adm_host($host,$config);
}

sub get_fls_vol_qtree
{
	my $self = shift;
	my ($host,$config) = @_;

	my $ld = $config->{'ld_ptr'};

	my ($fls,$vol,$qtree);

	if (exists($config->{'plugin_opts'}->{'filer'})) {
		if ($config->{'plugin_opts'}->{'filer'} !~ /^fls\d:vol\d$/) {
			mywarn('--filer option must be in the form of flsX:volX');
			return 1;
		}

		($fls,$vol) = split(':',$config->{'plugin_opts'}->{'filer'});

		mywarn('fls and vol being overridden on the command line:'
			. " $fls, $vol");
	} else {

		$fls = $ld->get_filer($host,$config);
		$vol = $ld->get_vol($host,$config);

		if (!defined($fls) || $fls eq '') {
			croak('Failed to determine filer information'
				. ' from local decision module '
				. "$host->{'group'} for $host->{'hostname'}\n");
		}
		if (!defined($vol) || $vol eq '') {
			croak('Failed to determine volume information'
				. ' from local decision module '
				. "$host->{'group'} for $host->{'hostname'}\n");
		}
	}

	$qtree = $ld->get_qtree_name($host,$config);

	debug("fls: $fls, vol $vol, qtree: $qtree");

	return ($fls,$vol,$qtree);

}

#
# The syntax of exports and quotas is similiar enough that removing
# the lines is the same.
#
sub remove_exports_quotas
{
	my $self = shift;
	my ($host,$fls,$vol,$qtree,$config) = @_;

	my $qtreedir = "/vol/$vol/$qtree";

	foreach my $file ('exports','quotas') {
		checkout($file);

		open(EXPORTS,"<$file") || croak("Couldn't open $file");
		my @lines = <EXPORTS>;
		close(EXPORTS);

		my @newlines = grep {!/^$qtreedir\s+/} @lines;

		my $fh = get_fh($file, '>');

		print $fh @newlines;

		close($fh) || croak("Couldn't close $file");

		show_diff($file);
		commit_diff($file);

		checkin($file,$host->{'hostname'},$config);

	}
	return 1;
}

sub remove_qtree
{
	my $self = shift;
	my ($fls,$vol,$qtree) = @_;

	my $qtreedir = "/$fls/$vol/$qtree";

	unless (-d $qtreedir) {
		return 1;
	}

	my $cmd = "$RM -rf $qtreedir 2>&1";

	if ($ENV{'ENABLE_DRYRUN'}) {
		dry_run($cmd);
		return 1;
	}

	if ($ENV{'ENABLE_VERBOSE'}) {
		verbose($cmd);
	}

	my $output = `$cmd`;
	if ($? != 0) {
		mywarn("Removing qtree failed with exit status $?: $!");
	}
	debug("output of removing qtree was: $output");

	return 1;
}

sub are_quotas_on
{
	my $self = shift;
	my ($fls, $vol) = @_;

        my $cmd = "$RSH $fls \"quota\" 2>&1";
	my $state = '';

	my $output = `$cmd`;
	
	my @lines = split("\n",$output);
	foreach my $line (@lines) {
		debug("line from filer: $line");
		if ($line =~ /^$vol: quotas are (.*)\.$/) {
			$state = $1;
			debug("quotastate: $state");
		}
	}

	if ($state eq 'on') {
		return 1;
	} elsif ($state eq 'off') {
		mywarn("Quotas are OFF on $fls:$vol! This is probably bad!");
		return 0;
	} else {
		mywarn("Can't determine quotastate of $fls:$vol! I will assume"
			. " they're off and leave them alone.\n");
		return 0;
	}
}


1;
