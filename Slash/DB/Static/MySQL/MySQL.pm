# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2001 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

package Slash::DB::Static::MySQL;
#####################################################################
#
# Note, this is where all of the ugly red headed step children go.
# This does not exist, these are not the methods you are looking for.
#
#####################################################################
use strict;
use Slash::Utility;
use URI ();
use vars qw($VERSION);
use base 'Slash::DB::MySQL';

($VERSION) = ' $Revision$ ' =~ /\$Revision:\s+([^\s]+)/;

# FRY: Hey, thinking hurts 'em! Maybe I can think of a way to use that.


# SQL STATUS FUNCTIONS.

########################################################
sub sqlShowMasterStatus {
	my($self) = @_;

	#$self->sqlConnect();
	my $stat = $self->{_dbh}->prepare("SHOW MASTER STATUS");
	$stat->execute;
	my $statlist = [];
	push @{$statlist}, $_ while $_ = $stat->fetchrow_hashref;

	return $statlist;
}


########################################################
sub sqlShowSlaveStatus {
	my($self) = @_;

	#$self->sqlConnect();
	my $stat = $self->{_dbh}->prepare("SHOW SLAVE STATUS");
	$stat->execute;
	my $statlist = [];
	push @{$statlist}, $_ while $_ = $stat->fetchrow_hashref;

	return $statlist;
}

########################################################
# for slashd
# This method is used in a pretty wasteful way
sub getBackendStories {
	my($self, $section) = @_;

	my $select;
	$select .= "stories.sid, stories.title, time, dept, stories.uid,";
	$select .= "alttext, image, stories.commentcount, stories.section as section,";
	$select .= "story_text.introtext, story_text.bodytext,topics.tid as tid";
	my $from = "stories, story_text, topics";
	my $where;
	$where .= "stories.sid = story_text.sid";
	$where .= " AND stories.tid=topics.tid";
	$where .= " AND time < NOW()";
	$where .= " AND stories.writestatus != 'delete'";
	if($section) {
		$where .= " AND stories.section=\"$section\" and displaystatus > -1";
	} else {
		$where .= " AND displaystatus = 0";
	}
	my $other = "ORDER BY time DESC LIMIT 10";

	my $returnable = $self->sqlSelectAllHashrefArray($select, $from, $where, $other);

	return $returnable;
}

########################################################
# This is only called if ssi is set
# 
# Deprecated code as this is now handled in the tasks!
# - Cliff 10/11/01
sub updateCommentTotals {
	my($self, $sid, $comments) = @_;
	my $hp = join ',', @{$comments->{0}{totals}};
	$self->sqlUpdate("stories", {
			hitparade	=> $hp,
			writestatus	=> 'ok',
			commentcount	=> $comments->{0}{totals}[0]
		}, 'sid=' . $self->{_dbh}->quote($sid)
	);
}

########################################################
# For slashd
# "LIMIT 10" chosen arbitrarily, actually could be LIMIT 5 but doesn't
# hurt much to kick in some more in case the caller has been changed to
# want more.
sub getNewStoryTopic {
	my($self) = @_;

	my $sth = $self->sqlSelectMany(
		'alttext, image, width, height, stories.tid as tid',
		'stories, topics',
		"stories.tid=topics.tid AND displaystatus = 0
		AND writestatus != 'delete' AND time < NOW()",
		'ORDER BY time DESC LIMIT 10'
	);

	return $sth;
}

########################################################
# For dailystuff
sub archiveComments {
	my($self) = @_;
	my $constants = getCurrentStatic();

	my $days_to_archive = $constants->{discussion_archive};
	# Close discussions.
	$self->sqlDo(
		"UPDATE discussions SET type='archived'
		 WHERE to_days(now()) - to_days(ts) > $days_to_archive AND 
		       (type='open' OR type='dirty')"
	);

	# Close associated story so that final archival .shtml is written
	# to disk. This is accomplished by the archive.pl task.
	$self->sqlDo(
		"UPDATE stories SET writestatus='archived'
		 WHERE to_days(now()) - to_days(time) > $days_to_archive AND
		       (writestatus='ok' OR writestatus='dirty')"
	);

	my $comments = $self->sqlSelectAll(
		'cid, discussions.id',
		'comments,discussions',
		"to_days(now()) - to_days(date) > $days_to_archive AND 
		discussions.id = comments.sid AND
		discussions.type = 'recycle' AND 
		comments.pid = 0"
	);
	for my $comment (@$comments) {
		next if !$comment or ref($comment) ne 'ARRAY' or !@$comment;
		my $local_count = $self->_deleteThread($comment->[0]);
		$self->setDiscussionDelCount($comment->[1], $local_count);
	}
}

sub _deleteThread {
	my($self, $cid, $level, $comments_deleted) = @_;
	$level ||= 0;

	if (!$cid) {
		errorLog("_deleteThread called with no cid");
		return 0;
	}

	my $count = 1;
	my @delList;
	$comments_deleted = \@delList if !$level;

	my $delkids = $self->getCommentChildren($cid);

	# Delete children of $cid.
	push @{$comments_deleted}, $cid;
	for (@{$delkids}) {
		my($cid) = @{$_};
		push @{$comments_deleted}, $cid;
		$count += $self->_deleteThread($cid, $level+1, $comments_deleted);
	}
	# And now delete $cid.
	$count += $self->deleteComment($cid);

	return $count;
}

########################################################
# For dailystuff
# This just updates the counts for the day before
# -Brian
sub updateStoriesCounts {
	my($self) = @_;
	my $constants = getCurrentStatic();
	my $counts = $self->sqlSelectAll(
		'dat,count(*)',
		'accesslog',
		"op='article' AND dat !='' AND to_days(now()) - to_days(ts) = 1",
		'GROUP BY(dat)'
	);

	for my $count (@$counts) {
		$self->sqlUpdate('stories', { -hits => "hits+$count->[1]" },
			'sid=' . $self->sqlQuote($count->[0])
		);
	}
}

########################################################
# For dailystuff
sub deleteDaily {
	my($self) = @_;
	my $constants = getCurrentStatic();

	$self->updateStoriesCounts();
	# Now for some random stuff
	$self->sqlDo("DELETE from pollvoters");
	$self->sqlDo("DELETE from moderatorlog WHERE
		to_days(now()) - to_days(ts) > $constants->{archive_delay}");
	$self->sqlDo("DELETE from metamodlog WHERE
		to_days(now()) - to_days(ts) > $constants->{archive_delay}");
	# Formkeys
	my $delete_time = time() - $constants->{'formkey_timeframe'};
	$self->sqlDo("DELETE FROM formkeys WHERE ts < $delete_time");
	# Note, on Slashdot, the next line locks the accesslog for several
	# minutes, up to 10 minutes if traffic has been heavy.
	$self->sqlDo("DELETE FROM accesslog WHERE date_add(ts,interval 48 hour) < now()");
}

########################################################
# For dailystuff
sub countDaily {
	my($self) = @_;
	my %returnable;

	my $constants = getCurrentStatic();

	($returnable{'total'}) = $self->sqlSelect("count(*)", "accesslog",
		"to_days(now()) - to_days(ts)=1");

	my $c = $self->sqlSelectMany("count(*)", "accesslog",
		"to_days(now()) - to_days(ts)=1 GROUP BY host_addr");
	$returnable{'unique'} = $c->rows;
	$c->finish;

	$c = $self->sqlSelectMany("count(*)", "accesslog",
		"to_days(now()) - to_days(ts)=1 GROUP BY uid");
	$returnable{'unique_users'} = $c->rows;
	$c->finish;

	$c = $self->sqlSelectMany("count(*)", "accesslog",
		"op='journal' AND to_days(now()) - to_days(ts)=1 GROUP BY uid");
	$returnable{'journals'} = $c->rows;
	$c->finish;

#	my($comments) = $self->sqlSelect("count(*)", "accesslog",
#		"to_days(now()) - to_days(ts)=1 AND op='comments'");

	$c = $self->sqlSelectMany("dat,count(*)", "accesslog",
		"to_days(now()) - to_days(ts)=1 AND
		(op='index' OR dat='index')
		GROUP BY dat");

	my(%indexes, %articles, %commentviews);

	while (my($sect, $cnt) = $c->fetchrow) {
		$indexes{$sect} = $cnt;
	}
	$c->finish;

	$c = $self->sqlSelectMany("dat,count(*),op", "accesslog",
		"to_days(now()) - to_days(ts)=1 AND op='article'",
		"GROUP BY dat");

	while (my($sid, $cnt) = $c->fetchrow) {
		$articles{$sid} = $cnt;
	}
	$c->finish;

	# clean the key table

# not used ... ?
# 	$c = $self->sqlSelectMany("dat,count(*)", "accesslog",
# 		"to_days(now()) - to_days(ts)=1 AND op='comments'",
# 		"GROUP BY dat");
# 	while (my($sid, $cnt) = $c->fetchrow) {
# 		$commentviews{$sid} = $cnt;
# 	}
# 	$c->finish;

	$returnable{'index'} = \%indexes;
	$returnable{'articles'} = \%articles;


	return \%returnable;
}

########################################################
# For dailystuff
sub updateStamps {
	my($self) = @_;
	my $columns = "uid";
	my $tables = "accesslog";
	my $where = "to_days(now())-to_days(ts)=1 AND uid > 0";
	my $other = "GROUP BY uid";

	my $E = $self->sqlSelectAll($columns, $tables, $where, $other);

	$self->sqlTransactionStart("LOCK TABLES users_info WRITE");

	for (@{$E}) {
		my $uid = $_->[0];
		$self->setUser($uid, {-lastaccess=>'now()'});
	}
	$self->sqlTransactionFinish();
}

########################################################
# For dailystuff
sub getDailyMail {
	my($self) = @_;

	my $columns = "stories.sid, stories.title, stories.section,
		users.nickname,
		stories.tid, stories.time, stories.dept,
		story_text.introtext, story_text.bodytext";
	my $tables = "stories, story_text, users";
	my $where = "time < NOW() AND TO_DAYS(NOW())-TO_DAYS(time)=1 ";
	$where .= "AND users.uid=stories.uid AND stories.sid=story_text.sid ";
	$where .= "AND stories.displaystatus=0 ";
	my $other = " ORDER BY stories.time DESC";

	my $email = $self->sqlSelectAll($columns, $tables, $where, $other);

	return $email;
}

########################################################
# For dailystuff
sub getMailingList {
	my($self) = @_;

	my $columns = "realemail,nickname,users.uid";
	my $tables  = "users,users_comments,users_info";
	my $where   = "users.uid=users_comments.uid AND users.uid=users_info.uid AND maillist=1";
	my $other   = "order by realemail";

	my $users = $self->sqlSelectAll($columns, $tables, $where, $other);

	return $users;
}

########################################################
# For dailystuff
# XXX Outdated, delete before tarball release - Jamie 2001/07/08
# If we go back to using this is may have issues -Brian
#sub getOldStories {
#	my($self, $delay) = @_;
#
#	my $columns = "sid,time,section,title";
#	my $tables = "stories";
#	my $where = "writestatus<5 AND writestatus >= 0 AND to_days(now()) - to_days(time) > $delay";
#
#	my $stories = $self->sqlSelectAll($columns, $tables, $where);
#
#	return $stories;
#}

########################################################
# For portald
sub getTop10Comments {
	my($self) = @_;
	my $c = $self->sqlSelectMany("stories.sid, title, cid, subject, date, nickname, comments.points",
		"comments, stories, users",
		"comments.points >= 4 AND users.uid=comments.uid AND comments.sid=stories.discussion",
		"ORDER BY date DESC LIMIT 10");

	my $comments = $c->fetchall_arrayref;
	$c->finish;

	formatDate($comments, 4, 4);

	return $comments;
}

########################################################
# For portald
sub randomBlock {
	my($self) = @_;
	my $c = $self->sqlSelectMany("bid,title,url,block",
		"blocks",
		"section='index' AND portal=1 AND ordernum < 0");

	my $A = $c->fetchall_arrayref;
	$c->finish;

	my $R = $A->[rand @$A];
	my($bid, $title, $url, $block) = @$R;

	$self->sqlUpdate("blocks", {
		title	=> "rand($title);",
		url	=> $url
	}, "bid='rand'");

	return $block;

}

########################################################
# For portald
# ugly method name
sub getAccesLogCountTodayAndYestarday {
	my($self) = @_;
	my $c = $self->sqlSelectMany("count(*), to_days(now()) - to_days(ts) as d", "accesslog", "", "GROUP by d order by d asc");

	my($today) = $c->fetchrow;
	my($yesterday) = $c->fetchrow;
	$c->finish;

	return ($today, $yesterday);

}

########################################################
# For portald
sub getSitesRDF {
	my($self) = @_;
	my $columns = "bid,url,rdf,retrieve";
	my $tables = "blocks";
	my $where = "rdf != '' and retrieve=1";
	my $other = "";
	my $rdf = $self->sqlSelectAll($columns, $tables, $where, $other);

	return $rdf;
}

########################################################
# For the sectionblock, which is generated by
# tasks/refresh_sectionblocks.pl in the defaut theme.
sub getSectionInfo {
	my($self) = @_;
	my $sections = $self->sqlSelectAllHashrefArray(
		'section', "sections",
		"isolate=0 and (section != '' and section != 'articles')
		ORDER BY section"
	);

	for (@{$sections}) {
		@{%{$_}}{qw(month day)} =
			$self->{_dbh}->selectrow_array(<<EOT);
SELECT MONTH(time), DAYOFMONTH(time)
FROM stories
WHERE section='$_->{section}' AND time < NOW() AND displaystatus > -1
ORDER BY time DESC LIMIT 1
EOT

		$_->{count} =
			$self->{_dbh}->selectrow_array(<<EOT);
SELECT COUNT(*) FROM stories
WHERE 	section='$_->{section}' AND
	TO_DAYS(NOW()) - TO_DAYS(time) <= 2 AND time < NOW() AND
	displaystatus > -1
EOT

	}

	return $sections;
}

########################################################
# For moderatord
sub tokens2points {
	my($self) = @_;
	my $constants = getCurrentStatic();
	my @log;
	# rtbl
	my $cursor = $self->sqlSelectMany(
		'uid', 
		'users_info',
		"tokens >= $constants->{maxtokens}"
	);

	# For some reason, the underlying calls to setUser will not work
	# without the extra locks on users_acl or users_param.
	$self->sqlTransactionStart('LOCK TABLES
		users READ,
		users_acl READ,
		users_info WRITE,
		users_comments WRITE,
		users_param READ,
		users_prefs WRITE'
	);
	# rtbl
	while (my($uid) = $cursor->fetchrow) {
		my $rtbl = $self->getUser($uid, 'rtbl') || 0;

		# rtbl
		push @log, Slash::getData(
			($rtbl) ? 'moderatord_tokennotgrantmsg' :
				  'moderatord_tokengrantmsg',
			{ uid => $uid }
		);

		$self->setUser($uid, {
			-lastgranted	=> 'now()',
			-tokens		=> ($rtbl) ? 
				'0' :
				"tokens*$constants->{token_retention}",
			-points		=> ($rtbl) ?
				'0' :
				($constants->{maxtokens} /
				 $constants->{tokensperpoint}),
		});
	}

	$cursor->finish;

	$cursor = $self->sqlSelectMany('users.uid as uid',
		'users,users_comments,users_info',
		"karma >= 0 AND
		points > $constants->{maxpoints} AND
		seclev < 100 AND
		users.uid=users_comments.uid AND
		users.uid=users_info.uid");
	$self->sqlTransactionFinish();

	$self->sqlTransactionStart("LOCK TABLES users_comments WRITE");
	while (my($uid) = $cursor->fetchrow) {
		# No update of lastgranted here as this is just a limiter.
		# these points should expire as per normal.
		$self->sqlUpdate('users_comments', {
			points => $constants->{maxpoints},
		}, "uid=$uid");
	}
	$self->sqlTransactionFinish();

	return \@log;
}

########################################################
# For moderatord
sub stirPool {
	my($self) = @_;
	my $stir = getCurrentStatic('stir');
	my $cursor = $self->sqlSelectMany("points,users.uid as uid",
			"users,users_comments,users_info",
			"users.uid=users_comments.uid AND
			 users.uid=users_info.uid AND
			 seclev <= 1 AND
			 points > 0 AND
			 to_days(now())-to_days(lastgranted) > $stir");

	my $revoked = 0;

	$self->sqlTransactionStart("LOCK TABLES users_info WRITE,users_comments WRITE");

	while (my($p, $u) = $cursor->fetchrow) {
		$revoked += $p;
		$self->setUser($u, {
			points 		=> '0',
			-lastgranted 	=> 'now()',
		});
	}

	$self->sqlTransactionFinish();
	$cursor->finish;

	# We aren't using this for Slashdot, feel free to turn this on if you
	# wish to use it (the proper return value is: $revoked)
	return 0;
}

########################################################
# For moderatord and some utils
sub getLastUser {
	my($self) = @_;
	# Why users_info instead of users?	- Cliff
	my($totalusers) = $self->sqlSelect("max(uid)", "users_info");

	return $totalusers;
}

########################################################
# For tailslash
sub pagesServed {
	my($self) = @_;
	my $returnable = $self->sqlSelectAll("count(*),ts",
			"accesslog", "1=1",
			"GROUP BY ts ORDER BY ts ASC");

	return $returnable;

}

########################################################
# For tailslash
sub maxAccessLog {
	my($self) = @_;
	my($returnable) = $self->sqlSelect("max(id)", "accesslog");;

	return $returnable;
}

########################################################
# For tailslash
sub getAccessLogInfo {
	my($self, $id) = @_;
	my $returnable = $self->sqlSelectAll("host_addr,uid,op,dat,ts,id",
				"accesslog", "id > $id",
				"ORDER BY ts DESC");
	formatDate($returnable, 4, 4, '%H:%M');
	return $returnable;
}

########################################################
# For moderatord
sub fetchEligibleModerators {
	my($self) = @_;
	my $constants = getCurrentStatic();
	my $eligibleUsers =
		$self->getLastUser() * $constants->{m1_eligible_percentage};

	# Should this list include authors if var[authors_unlimited] is 
	# non-zero?
	my $returnable =
		$self->sqlSelectAll("users_info.uid,count(*) as c",
			"users_info,users_prefs, accesslog",
			"users_info.uid < $eligibleUsers
			 AND users_info.uid=accesslog.uid
			 AND users_info.uid=users_prefs.uid
			 AND (op='article' or op='comments')
			 AND willing=1
			 AND karma >= 0
			 GROUP BY users_info.uid
			 HAVING c >= $constants->{m1_eligible_hitcount}
			 ORDER BY c");
	# Would it be better to NOT use the HAVING clause here and instead 
	# iterate thru a statement handle and triggering on [c] as the old code
	# did?
	#
	# Another idea:
	#	ALTER TABLE accesslog ADD INDEX uid (uid);
	#
	# Then SELECT ON/GROUP BY accesslog.uid?

	return $returnable;
}

########################################################
# For moderatord
sub updateTokens {
	my($self, $modlist) = @_;

	my $num_empty_uids = 0;
	for my $uid (@{$modlist}) {
		#if ($uid) {
		#	++$num_empty_uids;
		#	next;
		#}
		$self->setUser($uid, {
			-tokens	=> "tokens+1",
		});
	}
	if ($num_empty_uids) {
		errorLog("$num_empty_uids empty uids in updateTokens");
	}
	# if ($num_empty_uids) {
	#	errorLog("$num_empty_uids empty uids in updateTokens");
	#}
}

########################################################
# For dailyStuff
# 	This should only be run once per day, if this isn't
#	true, the simple logic below, breaks. This can be
#	fixed by moving the by_days trigger to a date
#	based system as opposed to a counter-based one,
#	or even adding a date component to expiry checks,
#	which might be a better solution.
sub checkUserExpiry {
	my($self) = @_;
	my($ret);

	# Subtract one from number of 'registered days left' for all users.
	$self->sqlUpdate(
		'users_info',
		{ -'expiry_days' => 'expiry_days-1' },
		'1=1'
	);

	# Now grab all UIDs that look to be expired, we explicitly exclude
	# authors from this search.
	$ret = $self->sqlSelectAll(
		'distinct uid',
		'users_info',
		'expiry_days < 0 or expiry_comm < 0'
	);

	# We only want the list of UIDs that aren't authors and have not already
	# expired. The extra perl code would be completely unavoidable if we had
	# subselects... *sigh*
	my(@returnable) = grep {
		my $user = $self->getUser($_->[0]);
		$_ = $_->[0];
		!($user->{author} || ! $user->{registered});
	} @{$ret};

	return \@returnable;
}

########################################################
# For moderation scripts.
#	This sub returns the moderatorlog IDs
#	that are eligible for consensus metamoderation.
#
sub getMetamodIDs {
	my($self) = @_;

	my($thresh, $num) = (
		getCurrentStatic('m2_consensus'),
		getCurrentStatic('m2_batchsize')
	);
	my $list = $self->sqlSelectAll(
		'distinct moderatorlog.id', 'moderatorlog, metamodlog',
		"m2count >= $thresh
		AND moderatorlog.id=metamodlog.mmid
		AND cuid IS NOT NULL
		AND flag = 10",
		($num) ? "LIMIT $num" : ''
	);
	$_ = $_->[0] for @{$list};

	return $list;
}

########################################################
# For moderation scripts.
#	This sub returns the meta-moderation information
#	given the appropriate M2ID (primary
#	key into the metamodlog table).
#
sub getMetaModerations {
	my($self, $mmid) = @_;

	my $ret = $self->sqlSelectAllHashrefArray(
		'*', 'metamodlog', "mmid=$mmid"
	);

	return $ret;
}

########################################################
# For moderation scripts.
#
#
sub updateM2Flag {
	my($self, $id, $val) = @_;

	$self->sqlUpdate('metamodlog', {
		-flag => $val,
	}, "id=$id");
}

########################################################
# For moderation scripts.
#
# Clears metamod flag for a given MMID.
sub clearM2Flag {
	my($self, $id) = @_;

	# Note that we only update flags that are in the:
	#	10 - M2 Pending
	# state.
	$self->sqlUpdate('metamodlog', {
		-flag => '0',
	}, "flag=10 and mmid=$id");
}

########################################################
# For freshenup.pl,archive.pl
#
#
sub getStoriesWithFlag {
	my($self, $writestatus, $order, $limit) = @_;
	
	my $sqlorder;
	$sqlorder = "ORDER BY time $order ";
	$sqlorder .= "LIMIT $limit" if $limit;
	
	# Currently only used by two tasks and we do NOT want stories
	# that are marked as "Never Display". If this changes, 
	# another method will be required. If such is created, I would
	# suggest getAllStoriesWithFlag() as the method name. We ALSO
	# don't want to mess with stories that haven't been displayed
	# yet!
	#
	# - Cliff 14-Oct-2001
	my $returnable = $self->sqlSelectAll(
		"sid,title,section",
		"stories", 
		"time < now() AND 
		writestatus='$writestatus' AND displaystatus > -1",
		$sqlorder
	);

	return $returnable;
}

########################################################
# For tasks/spamarmor.pl
#
# Please note use of closure. This is not an error.
#
#{
#my($usr_block_size, $usr_start_point);
#
#sub iterateUsers {
#	my($self, $blocksize, $start) = @_;
#
#	$start ||= 0;
#
#	($usr_block_size, $usr_start_point) = ($blocksize, $start)
#		if $blocksize && $blocksize != $usr_block_size;
#	$usr_start_point += $usr_block_size  + 1 if !$blocksize;
#
#	return $self->sqlSelectAllHashrefArray(
#		'*',
#		'users', '',
#		"ORDER BY uid LIMIT $usr_start_point,$usr_block_size"
#	);
#}
#}

########################################################
# For tasks/spamarmor.pl
#
# This returns a hashref of uid and realemail for 1/nth of the users
# whose emaildisplay param is set to 1 (armored email addresses).
# By default 1/7th, and which 1/7th determined by date.
#
# If emaildisplay is moved from users_param into the schema proper,
# this code will have to be changed.
#
sub getTodayArmorList {
	my($self, $buckets, $which_bucket) = @_;

	# Defaults to 7 for weekly rotation.
	$buckets = 7 if !defined($buckets);
	$buckets =~ /(\d+)/; $buckets = $1;

	# Default to day of year.
	$which_bucket = (localtime)[7] if !defined($which_bucket); 
	$which_bucket =~ /(\d+)/; $which_bucket = $1;
	$which_bucket %= $buckets;
	my $uid_aryref = $self->sqlSelectColArrayref(
		"uid",
		"users_param",
		"MOD(uid, $buckets) = $which_bucket AND name='emaildisplay' AND value=1",
		"ORDER BY uid"
	);
	return { } if !@$uid_aryref; # nobody wants armor? skip next select
	my $uid_list = join(",", @$uid_aryref);
	return $self->sqlSelectAllHashref(
		"uid",
		"uid, realemail",
		"users",
		"uid IN ($uid_list)"
	);
}

########################################################
# freshen.pl
sub deleteStoryAll {
	my($self, $sid) = @_;
	my $db_sid = $self->sqlQuote($sid);

	$self->sqlDo("DELETE FROM stories WHERE sid=$db_sid");
	$self->sqlDo("DELETE FROM story_text WHERE sid=$db_sid");
	my $discussion_id = $self->sqlSelect('id', 'discussions', "sid = $db_sid");
	$self->deleteDiscussion($discussion_id) if $discussion_id;
}

########################################################
# For tasks/author_cache.pl
# please don't unnecessarily stretch lines out to 250 columns -- pudge
# This runs once a day, I am not worried -Brian
# it makes it hard to read.  whether or not you are worried about
# it doesn't matter.  that it was not readable matters.  -- pudge
sub createAuthorCache {
	my($self) = @_;
	my $sql;
	$sql .= "REPLACE INTO authors_cache ";
	$sql .= "SELECT users.uid, nickname, fakeemail, homepage, 0, bio, author ";
	$sql .= "FROM users, users_info ";
	$sql .= "WHERE users.author =1 ";
	$sql .= "AND users.uid=users_info.uid";

	$self->sqlDo($sql);

	my $sql2;
	$sql2 .= "REPLACE INTO authors_cache ";
	$sql2 .= "SELECT users.uid, nickname, fakeemail, homepage, count(stories.uid), bio, author ";
	$sql2 .= "FROM users, stories, users_info ";
	$sql2 .= "WHERE stories.uid=users.uid ";
	$sql2 .= "AND users.uid=users_info.uid GROUP BY stories.uid";

	$self->sqlDo($sql2);
}

########################################################
# For tasks/flush_formkeys.pl
sub deleteOldFormkeys {
	my($self, $timeframe) = @_;
	my $nowtime = time();
	$self->sqlDo("delete from formkeys where ts < ($nowtime - (2*".$timeframe."))");
}

1;

__END__

=head1 NAME

Slash::DB::Static::MySQL - MySQL Interface for Slash

=head1 SYNOPSIS

	use Slash::DB::Static::MySQL;

=head1 DESCRIPTION

No documentation yet. Sue me.

=head1 SEE ALSO

Slash(3), Slash::DB(3).

=cut
