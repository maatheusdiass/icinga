#!/usr/bin/perl
# 2017 - pjs@eurotux.com

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use utils qw($TIMEOUT %ERRORS &print_revision &support);

my %errors;

for my $t (qw(ext2 ext3 ext4)) {
	next unless(-d "/sys/fs/$t");
	opendir(my $dir, "/sys/fs/$t") || error("Can't open dir /sys/fs/$t: $!\n");
	while(my $e = readdir($dir)) {
		chomp($e);
		next if($e =~ /^\.\.?$/);
		next unless(-r "/sys/fs/$t/$e/errors_count");

		open(my $f, '<', "/sys/fs/$t/$e/errors_count") || error("Can't open file /sys/fs/$t/$e/errors_count: $!");
		my $number = <$f>;
		close($f);
		chomp($number);
		error("Invalid error count while checking $e: $number") unless $number =~ /^\d$/;

		$errors{$e} = $number if($number > 0);
	}
	closedir($dir);
}

if(scalar(keys %errors) > 0) {
	print "ERROR - " . join(',', keys %errors) . "\n";
	exit $ERRORS{'CRITICAL'};
} else {
	print "OK - no errors\n";
	exit $ERRORS{'OK'};
}

sub error {
	my $e = shift();
	print "UNKNOWN - $e\n";
	exit $ERRORS{'UNKNOWN'};
}
