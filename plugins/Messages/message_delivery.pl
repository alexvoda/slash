#!/usr/bin/perl -w
# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2001 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

use strict;
use File::Spec::Functions;
use Slash::Utility;

my $me = 'message_delivery.pl';

use vars qw( %task );

$task{$me}{timespec} = '5-59/5 * * * *';
$task{$me}{code} = sub {
	my($virtual_user, $constants, $slashdb, $user) = @_;

	my $messages = getObject('Slash::Messages');
	unless ($messages) {
		slashdLog("$me: could not instantiate Slash::Messages object");
		return;
	}

	messagedLog("$me begin");

	my($successes, $failures) = (0, 0);
	my $count = $constants->{message_process_count} || 10;
	my $msgs  = $messages->gets($count);
	my @good  = $messages->process(@$msgs);

	my %msgs  = map { ($_->{id}, $_) } @$msgs;

	for (@good) {
		messagedLog("msg \#$_ sent successfully.");
		delete $msgs{$_};
		++$successes;
	}

	for (sort { $a <=> $b } keys %msgs) {
		messagedLog("Error: msg \#$_ not sent successfully.");
		++$failures;
	}

	messagedLog("$me end");
	if ($successes or $failures) {
		return "sent $successes ok, $failures failed";
	} else {
		return ;
	}
};

sub messagedLog {
	chomp @_;
	my $fh = gensym();
	my $dir = getCurrentStatic('logdir');
	my $log = catfile($dir, "messaged.log");
	my $log_msg = scalar(localtime) . "\t@_\n";
	open $fh, ">> $log\0" or die "Can't append to $log: $!\nmsg: @_\n";
	print $fh $log_msg;
	close $fh;
}

1;
