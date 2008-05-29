#!/usr/bin/perl -w
# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$
#
# This task checks urls to see if they're still alive, and sets their
# validated titles
#
use Slash::Constants ':slashd';
use LWP::Parallel::UserAgent;
use Encode 'encode_utf8';

use strict;

use vars qw( %task $me $task_exit_flag );

$task{$me}{timespec} = '0-59/2 * * * *';
$task{$me}{timespec_panic_1} = '1-59/10 * * * *';
$task{$me}{timespec_panic_2} = '';
$task{$me}{on_startup} = 1;
$task{$me}{fork} = SLASHD_NOWAIT;
$task{$me}{code} = sub {
	my($virtual_user, $constants, $slashdb, $user, $info, $gSkin) = @_;

	my $reader = getObject("Slash::DB", { type => 'reader'});

	my $start_time = time();
	my $timeout = 60;

	my $ua = LWP::UserAgent->new;
	$ua->agent($constants->{url_checker_user_agent}) if $constants->{url_checker_user_agent};
	$ua->timeout(20);

	my $urls = $reader->getUrlsNeedingFirstCheck({ limit_to_firehose => 1 });
	my $refresh_urls = $reader->getUrlsNeedingRefresh();

	my $urls_hr;

	my @all_urls = (@$urls, @$refresh_urls);

	foreach (@all_urls) {
		$urls_hr->{$_->{url}} = $_;
	}

	URL_CHECK: while (@all_urls) {
		my @set = splice(@all_urls, 0, 20);

		# Don't run forever...
		if (time > $start_time + $timeout) {
			slashdLog("Aborting checking urls, too much elapsed time");
			last URL_CHECK;
		}
		if ($task_exit_flag) {
			slashdLog("Aborting url_checker, got SIGUSR1");
			last URL_CHECK;
		}

		my $ua = LWP::Parallel::UserAgent->new();
		$ua->duplicates(0);
		$ua->timeout   (15);
		$ua->redirect  (1);

		foreach (@set) {
			my $req = HTTP::Request("GET", $_->{url});
			$ua->register($req);
		}

		my $entries = $ua->wait();

		foreach (keys %$entries) {
			my $res = $entries->{$_}->response;
			my $url = $res->request->url;
			my $item = $urls_hr->{$url};
			my $url_update = { url_id => $item->{url_id} };

			if ($res->is_success) {
				my $validatedtitle = $res->{title};
				if (defined $validatedtitle) {
					$url_update->{validatedtitle} = strip_notags($validatedtitle);
					$url_update->{"-last_success"} = "NOW()";
					$url_update->{is_success} = 1;
					$url_update->{"-believed_fresh_until"} = "DATE_ADD(NOW(), INTERVAL 2 DAY)";
				}
			} else {
				$url_update->{is_success} = 0;
				$url_update->{"-believed_fresh_until"} = "DATE_ADD(NOW(), INTERVAL 30 MINUTE)";
			}
			# If this is a second or greater, we adjust the amount of time between refreshes to slowly increase
			# time between refreshes
			if ($url->{last_attempt}) {
				my $secs = $slashdb->sqlSelect("UNIX_TIMESTAMP(NOW()) - UNIX_TIMESTAMP('$url->{last_attempt}')");
				my $decay = 1.2;
				my $secs_until_next = int($secs * $decay);
				$url_update->{"-believed_fresh_until"} = "DATE_ADD(NOW(), INTERVAL $secs_until_next SECOND)";
			}

			$url_update->{status_code} = $res->code;
			$url_update->{reason_phrase} = $res->reason;
			$url_update->{"-last_attempt"} = "NOW()";
		}

	}
};

1;
