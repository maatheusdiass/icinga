#!/usr/bin/perl -w
use strict;
use warnings;
use File::Basename;
use Getopt::Long qw(GetOptions);

# @author Dean Wilson http://www.unixdaemon.net/nagios_plugins.html
# @author Duarte Rocha <dfr@eurotux.com>
# @date 22-05-2009
# random field order fix, bind support and noauto support by roa@eurotux.com Oct 2015
# excluded mount support by rfp@eurotux.com Dec 2015

# NOTE 1: if you are getting strange errors while running as non-root, try running blkid as root once and try again
# NOTE 2: doesn't pick up offline swap partitions

# deal with unexpected problems.
$SIG{__DIE__} = sub { print "@_"; exit 3; };


## Rerun as root if not already running and when possible
if ($< != 0) {
    # check if command is allowed
    my $my_safe_sudo_test = 'sudo -n -l '.quotemeta($0).' '.join(' ', map(quotemeta, @ARGV)).' 2>/dev/null';
    my $sudocomplete = `$my_safe_sudo_test`;
    chomp($sudocomplete);
    if ($? == 0 && $sudocomplete ne '') {
	# only rerun with sudo if no password needed
	system('sudo -n -v 2>/dev/null');
	exec('sudo', '-H', '-n', $0, @ARGV) if $? == 0;
    }
}
if ($< != 0) {
    print "Not running as root and couldn't sudo. Please correct.\n";
    exit 3;
}


# special mountpoints we know we will never want to check (this is in addition to whatever is given in --excluded or --excludedre)
my $always_ignore_mounts = qr!^(/var/named/chroot|/var/lib/docker|/docker)(/.*)?!;

my $fstab = '/etc/fstab';
# Labels, UUID and other stuff
my $blkid = '/sbin/blkid';
my $lsblk = '/usr/bin/lsblk';
my %devices_by_number; # devices by number
my (%mounted_disks, %fstab_disks); # store the read details.
my %blkid_info; # details from blkid
my @excluded_mounts;
my %excluded_check;

# get options
my ($p_blkid, $p_lsblk, $excludedre);
GetOptions('excluded=s' => \@excluded_mounts,
	   'excludedre=s' => \$excludedre,
           'lsblk=s' => \$p_lsblk,
           'blkid=s' => \$p_blkid
	) or die "Usage: $0 [--excluded mountpoint [ --excluded mountpoint ... ]] [--excludedre regex] [--lsblk 'command to invoke lsblk, e.g. /opt/other/lsblk' | --blkid 'command to invoke blkid, e.g. sudo blkid'] \n";
# parameter check and setting
if (defined($p_lsblk)) {
    die '--lsblk and --blkid are mutually exclusive' if defined($p_blkid);
    $lsblk = $p_lsblk;
}
$blkid = $p_blkid if defined($p_blkid);
# initialize hash with optional excluded mounts, for faster checking
@excluded_check{@excluded_mounts} = undef;
# compile given regex
my $excluded_regex;
if (defined($excludedre)) {
    eval { $excluded_regex = qr/$excludedre/ };
    if ($@) {
	print "Invalid regular expression given: $excludedre\n";
	exit 3;
    }
}

########################################################
# get active devices and respective numbers
########################################################

foreach my $sysblk (glob '/sys/block/*') {
    my $device = '/dev/'.basename($sysblk);
    open my $sysblk_fh, '<', "$sysblk/dev" or next;
    my $devno = <$sysblk_fh>;
    chomp $devno;
    close $sysblk_fh;
    $devices_by_number{$devno} = $device;
}


########################################################
# get the device and mount point of the mounted disks
########################################################

open( my $mount_fh, '/proc/mounts')
  || die "Failed to open /proc/mounts: $!";

while ( <$mount_fh> ) {
  next unless m!(^/dev/)|(^[\w\.-]+:/)|(^//.+?/.+)!;
  my ($device, $mount_point) = (split(/\s+/, $_))[0,1];
  next if $mount_point =~ $always_ignore_mounts;
  $device =~ s|([^:])/$|$1|g;  # e.g. machine:/nfsexport/ is the same as machine:/nfsexport
  $mounted_disks{$mount_point} = $device unless ( exists($excluded_check{$mount_point}) || ( defined($excluded_regex) && $mount_point =~ $excluded_regex ) );
#  print "MOUNT POINT: $mount_point\n";
}

close $mount_fh;


########################################################
# get info from partitions and devices (Label, UUID, etc...)
########################################################

# unless given in command line, prefer lsblk if available as it doesn't depend
# on being run as root at least once like blkid
if (!defined($p_blkid) && ( defined($p_lsblk) || -x $lsblk)) {
  # unfortunatly only recent versions of lsblk support -p to get the full device path
  # so we'll have to guess the device based on the type
  open( my $lsblk_fh, "$lsblk -n -P -o TYPE,NAME,LABEL,UUID |")
    || die "Failed to open $lsblk: $!";
  
  while( <$lsblk_fh> ) {
    next unless m!!;
    my ($devtype, $devbase, $fields) = /TYPE="([^"]+)"\s+NAME="([^"]+)"\s+(.+)/ or next;
    my $device = ( $devtype =~ /^(lvm|dm)$/ ? '/dev/mapper' : '/dev' ) . "/$devbase";
    while ($fields =~ /(\S+)=(\"[^"]*\"|\S)/g) {
      my $key = $1;
      my $value = $2;
      $value =~ s/[\"\']//g;
      $blkid_info{$key}{$value} = $device if $key ne "" && $value ne "";
    }
  }
  close $lsblk_fh;
}
else {
  # fall back to blkid for older systems
  open( my $blkid_fh, "$blkid |")
    || die "Failed to open $blkid: $!";
  
  while( <$blkid_fh> ) {
    next unless m!!;
    my ($device, $fields) = split(/:?\s+/,$_, 2);
    while ($fields =~ /(\S+)=(\"[^"]*\"|\S)/g) {
      my $key = $1;
      my $value = $2;
      $value =~ s/[\"\']//g;
      $blkid_info{$key}{$value} = $device;
    }
  }
  close $blkid_fh;
}

########################################################
# get the device and mount point from fstab (what should be mounted)
########################################################

open( my $fstab_fh, $fstab)
  || die "Failed to open $fstab: $!";


while (<$fstab_fh>) {
  #  next unless m!(^/dev/)|(^LABEL)|(^UUID)|(^\w+:/\w+)!;
  chomp;
  next if /^\s*#/ || /^$/; # ignore comments
  my ($device, $mount_point, $type, $options) = (split(/\s+/, $_))[0,1,2,3];
  next if $device =~ m!(^/dev/cdrom)|(^/dev/fd\d+)|(^none$)|(^cgroup$)! ||
      $mount_point =~ /(^none$)|(^swap$)/ ||
      $type =~ /^(sysfs)|(swap)|(proc)|(devpts)|(usbfs)|(debugfs)|(tmpfs)$/; # ignore floppy, cdrom, proc, sys, swap, cgroup, etc

  # non-root mount points can be terminated with slash on fstab, but internally we need to strip that
  $mount_point =~ s|([^/]+)/+$|$1|;
  next if $mount_point =~ $always_ignore_mounts || exists($excluded_check{$mount_point}) || ( defined($excluded_regex) && $mount_point =~ $excluded_regex );

  # parse options
  my %opt = map { my ($o,$v) = split /=/; $o => $v; } split(/,\s*/, $options) if defined($options);
  # ignore fstab entries with noauto: it's ok if they are mounted but don't care if they're not
  if (exists($opt{'noauto'})) {
      delete $mounted_disks{$mount_point};
      next;
  }

  # bind mount support
  if (exists($opt{'bind'})) {
    my $devhex = sprintf("%04x", (stat $device)[0]);
    my $devno = join(':', map { hex } $devhex =~ /(..)/g);
    $device = $devices_by_number{$devno} if exists($devices_by_number{$devno});
  }
  # label and uuid support
  elsif ($device =~ m/^(LABEL|UUID)=(\S+)/) {
    my $type = $1;
    my $value = $2;
    $value =~ s/[\"\']//g;
    if (exists $blkid_info{$type}{$value}){
      $device = $blkid_info{$type}{$value};
      # note that if the device isn't found, it will always be reported
    }
  }

  $fstab_disks{$mount_point} = $device;
}

close $fstab_fh;

########################################################
# find inconsistent mounts
########################################################

my @not_mounted    = sort grep { ! exists $mounted_disks{$_} } keys %fstab_disks;
my @not_persistent = sort grep { ! exists $fstab_disks{$_}   } keys %mounted_disks;

########################################################
# Build output
########################################################

# Debug
#print "MOUNTED:\n";
#while ( my ($k,$v) = each %mounted_disks ) {
#	    print "$k => $v\n";
#}
#print "FSTAB:\n";
#while ( my ($k,$v) = each %fstab_disks) {
#	    print "$k => $v\n";
#}

my $message = "OK: All disks are mounted and persistent";
my $exit_code = 0;

$exit_code = 2                                   if (@not_mounted || @not_persistent);
$message  = "ERROR: "                            if (@not_mounted || @not_persistent);
$message .= "@not_mounted not mounted"       if  @not_mounted;
$message .= " -- "                               if (@not_mounted && @not_persistent);
$message .= "@not_persistent not persistent" if  @not_persistent;

print "$message\n";
exit $exit_code;
