#!/usr/bin/perl -w
# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2001 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

use strict;
use Slash;
use Slash::Display;
use Slash::Utility;

#################################################################
sub main {
	my $slashdb = getCurrentDB();
	my $form = getCurrentForm();

	my %ops = (
		edit		=> \&editpoll,
		save		=> \&savepoll,
		'delete'	=> \&deletepolls,
		list		=> \&listpolls,
		default		=> \&default,
		vote		=> \&vote,
		get		=> \&poll_booth,
	);

	my $op = $form->{op};
	if (defined $form->{'aid'} && $form->{'aid'} !~ /^\-?\d$/) {
		undef $form->{'aid'};
	}

	header(getData('title'), $form->{section});

	$op = 'default' unless $ops{$form->{op}};
	$ops{$op}->($form);

	writeLog($form->{'qid'});
	footer();
}

#################################################################
sub poll_booth {
	my($form) = @_;

	print pollbooth($form->{'qid'}, 0, 1);
}

#################################################################
sub default {
	my($form) = @_;

	if (!$form->{'qid'}) {
		listpolls(@_);
	} elsif (! defined $form->{'aid'}) {
		poll_booth(@_);
	} else {
		my $vote = vote(@_);
		if (getCurrentStatic('poll_discussions')) {
			my $slashdb = getCurrentDB();
			my $discussion = $slashdb->getPollQuestion($form->{'qid'}, 'discussion');
			printComments($discussion)
		}
	}
}

#################################################################
sub editpoll {
	my($form) = @_;

	my($qid) = $form->{'qid'};
	unless (getCurrentUser('is_admin')) {
		default(@_);
		return;
	}
	my $slashdb = getCurrentDB();

	my($currentqid) = $slashdb->getVar('currentqid', 'value');
	my $question = $slashdb->getPollQuestion($qid, ['question', 'voters']);
	$question->{voters} ||= 0;

	my $answers = $slashdb->getPollAnswers($qid, ['answer', 'votes']) if $qid;

	slashDisplay('editpoll', {
		checked		=> $currentqid eq $qid ? ' CHECKED' : '',
		qid		=> $qid,
		question	=> $question,
		answers		=> $answers,
	});
}

#################################################################
sub savepoll {
	my($form) = @_;

	unless (getCurrentUser('is_admin')) {
		default(@_);
		return;
	}
	my $slashdb = getCurrentDB();
	my $constants = getCurrentStatic();
	slashDisplay('savepoll');
	#We are lazy, we just pass along $form as a $poll
	my $qid = $slashdb->savePollQuestion($form);

	if ($constants->{poll_discussions}) {
		my $discussion = $slashdb->createDiscussion($form->{question},
			"$constants->{rootdir}/pollBooth.pl?op=vote&qid=$qid", $form->{topic}
		);
		$slashdb->setPollQuestion($qid, { discussion => $discussion });
	}
	$slashdb->setStory($form->{sid}, { poll => $qid }) if $form->{sid};
}

#################################################################
sub vote {
	my($form) = @_;

	my $qid = $form->{'qid'};
	my $aid = $form->{'aid'};

	return unless $qid;

	my $slashdb = getCurrentDB();

	my(%all_aid) = map { ($_->[0], 1) }
		@{$slashdb->getPollAnswers($qid, ['aid'])};

	if (! keys %all_aid) {
		print getData('invalid');
		# Non-zero denotes error condition and that comments
		# should not be printed.
		return;
	}

	my $question = $slashdb->getPollQuestion($qid, ['voters', 'question']);
	my $notes = getData('display');
	if (getCurrentUser('is_anon') and ! getCurrentStatic('allow_anonymous')) {
		$notes = getData('anon');
	} elsif ($aid > 0) {
		my $id = $slashdb->getPollVoter($qid);

		if ($id) {
			$notes = getData('uid_voted');
		} elsif (exists $all_aid{$aid}) {
			$notes = getData('success', { aid => $aid });
			$slashdb->createPollVoter($qid, $aid);
			$question->{voters}++;
		} else {
			$notes = getData('reject', { aid => $aid });
		}
	}

	my $answers  = $slashdb->getPollAnswers($qid, ['answer', 'votes']);
	my $maxvotes = $slashdb->getPollVotesMax($qid);
	my @pollitems;
	for (@$answers) {
		my($answer, $votes) = @$_;
		my $imagewidth	= $maxvotes
			? int(350 * $votes / $maxvotes) + 1
			: 0;
		my $percent	= $question->{voters}
			? int(100 * $votes / $question->{voters})
			: 0;
		push @pollitems, [$answer, $imagewidth, $votes, $percent];
	}

	slashDisplay('vote', {
		qid		=> $qid,
		width		=> '99%',
		title		=> $question->{question},
		voters		=> $question->{voters},
		pollitems	=> \@pollitems,
		notes		=> $notes
	});
}

#################################################################
sub deletepolls {
	my($form) = @_;
	if (getCurrentUser('is_admin')) {
		my $slashdb = getCurrentDB();
		$slashdb->deletePoll($form->{'qid'});
	}
	listpolls(@_);
}

#################################################################
sub listpolls {
	my($form) = @_;
	my $slashdb = getCurrentDB();
	my $min = $form->{min} || 0;
	my $questions = $slashdb->getPollQuestionList($min);
	my $sitename = getCurrentStatic('sitename');

	# Just me, but shouldn't title be in the template?
	# yes
	slashDisplay('listpolls', {
		questions	=> $questions,
		startat		=> $min + @$questions,
		admin		=> getCurrentUser('seclev') >= 100,
		title		=> "$sitename Polls",
		width		=> '99%'
	});
}

#################################################################
createEnvironment();
main();

1;
