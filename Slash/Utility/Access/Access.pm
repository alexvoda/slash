# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2001 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

package Slash::Utility::Access;

=head1 NAME

Slash::Utility::Access - SHORT DESCRIPTION for Slash


=head1 SYNOPSIS

	use Slash::Utility;
	# do not use this module directly

=head1 DESCRIPTION

LONG DESCRIPTION.


=head1 EXPORTED FUNCTIONS

=cut

use strict;
use Digest::MD5 'md5_hex';
use HTML::Entities;
use Slash::Display;
use Slash::Utility::Environment;
use Slash::Utility::System;

use base 'Exporter';
use vars qw($VERSION @EXPORT);

($VERSION) = ' $Revision$ ' =~ /\$Revision:\s+([^\s]+)/;
@EXPORT	   = qw(
	checkFormPost
	compressOk
	filterOk
	getFormkey
	getFormkeyId
	submittedAlready
	allowExpiry
	setUserExpired
	intervalString
);

# really, these should not be used externally, but we leave them
# here for reference as to what is in the package
# @EXPORT_OK = qw(
# 	intervalString
# );

########################################################
# we need to reorg this ... maybe get rid of the need for it -- pudge
sub getFormkeyId {
	my($uid) = @_;
	my $user = getCurrentUser();
	my $form = getCurrentForm();

	# this id is the key for the commentkey table, either UID or
	# unique hash key generated by IP address
	my $id;

	# if user logs in during submission of form, after getting
	# formkey as AC, check formkey with user as AC
	if ($user->{uid} > 0 && $form->{rlogin} && length($form->{upasswd}) > 1) {
		getAnonCookie($user);
		$id = $user->{anon_id};
	} elsif ($uid > 0) {
		$id = $uid;
	} else {
		$id = $user->{anon_id};
	}
	return $id;
}

#========================================================================

=head2 getFormkey()

Creates a random formkey (well, as random as random gets)

=over 4

=item Return value

Return a random value based on alphanumeric characters

=back

=cut

sub getFormkey {
	return getAnonId(1);
}

## NEED DOCS
#========================================================================
sub intervalString {
	# Ok, this isn't necessary, but it makes it look better than saying:
	#  "blah blah submitted 23333332288 seconds ago"
	my($interval) = @_;
	my $interval_string;

	if ($interval > 60) {
		my($hours, $minutes) = 0;
		if ($interval > 3600) {
			$hours = int($interval/3600);
			if ($hours > 1) {
				$interval_string = $hours . ' ' . Slash::getData('hours', '', '');
			} elsif ($hours > 0) {
				$interval_string = $hours . ' ' . Slash::getData('hour', '', '');
			}
			$minutes = int(($interval % 3600) / 60);

		} else {
			$minutes = int($interval / 60);
		}

		if ($minutes > 0) {
			$interval_string .= ", " if $hours;
			if ($minutes > 1) {
				$interval_string .= $minutes . ' ' . Slash::getData('minutes', '', '');
			} else {
				$interval_string .= $minutes . ' ' . Slash::getData('minute', '', '');
			}
		}
	} else {
		$interval_string = $interval . ' ' . Slash::getData('seconds', '', '');
	}

	return $interval_string;
}

#========================================================================
sub submittedAlready {
	my($formkey, $formname, $err_message) = @_;
	my $slashdb = getCurrentDB();

	# find out if this form has been submitted already
	my($submitted_already, $submit_ts) = $slashdb->checkForm($formkey, $formname)
		or ($$err_message = Slash::getData('noformkey', '', ''), return);

	if ($submitted_already) {
		my $interval_string = $submit_ts
			? intervalString(time - $submit_ts)
			: ""; # never got submitted, don't know time
		$$err_message = Slash::getData('submitalready', {
			interval_string => $interval_string
		}, '');
	}
	return $submitted_already;
}

#========================================================================
sub checkFormPost {
	my($formname, $limit, $max, $id, $err_message) = @_;
	my $slashdb = getCurrentDB();
	my $constants = getCurrentStatic();
	my $user = $slashdb->getCurrentUser();

	my $uid;

	if ($user->{uid} == $constants->{anonymous_coward_uid}) {
		$uid = $user->{ipid};
	} else {
		$uid = $user->{uid};
	}

	my $formkey_earliest = time() - $constants->{formkey_timeframe};
	# If formkey starts to act up, me doing the below
	# may be the cause
	my $formkey = getCurrentForm('formkey');

	my $last_submitted = $slashdb->getSubmissionLast($id, $formname);

	my $interval = time() - $last_submitted;

	if ($interval < $limit) {
		$$err_message = Slash::getData('speedlimit', {
			limit_string	=> intervalString($limit),
			interval_string	=> intervalString($interval)
		}, '');
		return;

	} else {
		if ($slashdb->checkTimesPosted($formname, $max, $id, $formkey_earliest)) {
			undef $formkey unless $formkey =~ /^\w{10}$/;

			unless ($formkey && $slashdb->checkFormkey($formkey_earliest, $formname, $id, $formkey)) {
				$slashdb->createAbuse("invalid form key", $formname, $ENV{QUERY_STRING});
				$$err_message = Slash::getData('invalidformkey', '', '');
				return;
			}

			if (submittedAlready($formkey, $formname, $err_message)) {
				$slashdb->createAbuse("form already submitted", $formname, $ENV{QUERY_STRING});
				return;
			}

		} else {
			$slashdb->createAbuse("max form submissions $max reached", $formname, $ENV{QUERY_STRING});
			$$err_message = Slash::getData('maxposts', {
				max		=> $max,
				timeframe	=> intervalString($constants->{formkey_timeframe})
			}, '');
			return;
		}
	}
	return 1;
}

#========================================================================
sub filterOk {
	my($formname, $field, $content, $error_message) = @_;

	my $slashdb = getCurrentDB();
	my $user = getCurrentUser();

	my $filters = $slashdb->getContentFilters($formname, $field);

	# hash ref from db containing regex, modifier (gi,g,..),field to be
	# tested, ratio of field (this makes up the {x,} in the regex, minimum
	# match (hard minimum), minimum length (minimum length of that comment
	# has to be to be tested), err_message message displayed upon failure
	# to post if regex matches contents. make sure that we don't select new
	# filters without any regex data.
	for (@$filters) {
		my($number_match, $regex);
		my $raw_regex		= $_->[2];
		my $modifier		= 'g' if $_->[3] =~ /g/;
		my $case		= 'i' if $_->[3] =~ /i/;
		my $field		= $_->[4];
		my $ratio		= $_->[5];
		my $minimum_match	= $_->[6];
		my $minimum_length	= $_->[7];
		my $err_message		= $_->[8];
		my $isTrollish		= 0;

		my $text_to_test = decode_entities($content);

		$text_to_test		=~ s/\xA0/ /g;
		$text_to_test		=~ s/\<br\>/\n/gi;

		next if ($minimum_length && length($text_to_test) < $minimum_length);

		if ($minimum_match) {
			$number_match = "{$minimum_match,}";
		} elsif ($ratio > 0) {
			$number_match = "{" . int(length($text_to_test) * $ratio) . ",}";
		}

		$regex = $raw_regex . $number_match;
		my $tmp_regex = $regex;

		$regex = $case eq 'i' ? qr/$regex/i : qr/$regex/;

		if ($modifier eq 'g') {
			if ($text_to_test =~ /$regex/g) {
				$$error_message = $err_message;
				$slashdb->createAbuse("content filter", $formname, $text_to_test);
				return 0;
			}
		} else {
			if ($text_to_test =~ /$regex/) {
				$$error_message = $err_message;
				$slashdb->createAbuse("content filter", $formname, $text_to_test);
				return 0;
			}
		}
	}
	return 1;
}

#========================================================================
sub compressOk {
	# leave it here, it causes problems if use'd in the
	# apache startup phase
	require Compress::Zlib;
	my($formname, $field, $content) = @_;

	my $slashdb   = getCurrentDB();
	my $constants = getCurrentStatic();
	my $user      = getCurrentUser();
	my $uid;

	if ($user->{uid} == $constants->{anonymous_coward_uid}) {
		$uid = $user->{ipid};
	} else {
		$uid = $user->{uid};
	}

	# interpolative hash ref. Got these figures by testing out
	# several paragraphs of text and saw how each compressed
	# the key is the ratio it should compress, the array lower,upper
	# for the ratio. These ratios are _very_ conservative
	# a comment has to be absolute shit to trip this off
	my $limits = {
		1.3 => [10,19],
		1.1 => [20,29],
		.8 => [30,44],
		.5 => [45,99],
		.4 => [100,199],
		.3 => [200,299],
		.2 => [300,399],
		.1 => [400,1000000],
	};

	my $length = length($content);

	# too short to bother
	return 1 if $length < 10;

	# Ok, one list ditch effort to skew out the trolls!
	for (sort { $a <=> $b } keys %$limits) {
		# if it's within lower to upper
		if ($length >= $limits->{$_}->[0] && $length <= $limits->{$_}->[1]) {

			# if is >= the ratio, then it's most likely a
			# troll comment
			my $comlen = length(Compress::Zlib::compress($content));
			if (($comlen / $length) <= $_) {
				$slashdb->createAbuse("content compress", $formname, $content);
				return 0;
			}
		}
	}

	return 1;
}

#========================================================================

=head2 allowExpiry()

Returns whether the system allows user expirations or not.

=over 4

=item Return value

Boolean value. True if users are to be expired, false if not.

The following variables can control this behavior:
	min_expiry_days
	max_expiry_days
	min_expiry_comm
	max_expiry_comm

	do_expiry

=back

=cut

sub allowExpiry {
	my $constants = getCurrentStatic();

	# We only perform the check if any of the following are turned on.
	return ($constants->{min_expiry_days} > 0 ||
		$constants->{max_expiry_days} > 0 ||
		$constants->{min_expiry_comm} > 0 ||
		$constants->{max_expiry_comm} > 0
	) && $constants->{do_expiry};
}

#========================================================================

=head2 setUserExpiry($uid, $val)

Set/Clears the expired status on the given UID based on $val. If $val
is non-zero, then expiration will be performed on the user, this
include:
	- Generating a registration ID for the user so that they can re-register.
	- Marking all forms in vars.[expire_forms] as read-only.
	- Clearing the registration flag.
	- Sending the registration email which notifies user of expiration.

If $val is non-zero, then the above operations are "cleared" by
performing the following:

	- Clearing the registration ID associated with the user.
	  (it's not the job of this routine to perform checks on reg-id)
	- Unmarking all forms marked read-only (note: this is NOT a deletion!)
	- Setting the registration flag.

=over 4

=item Return value

None.

=back

=cut

sub setUserExpired {
	my($uid, $val) = @_;

	my $user = getCurrentUser($uid);
	my $slashdb = getCurrentDB();
	my $constants = getCurrentStatic();

	# Apply the appropriate readonly flags.
	for (split /,\s+/, $constants->{expire_forms}) {
		$slashdb->setReadOnly($_, $uid, $val, 'expired');
	}

	if ($val) {
		# Determine regid. We want to strive for as much randomness as we
		# can without getting overly complex. Let's just create a string
		# that should have a reasonable degree of uniqueness by user.
		#
		# Now, how likely is it that this will result in a collision?
		# Note that we obscure with an MD5 hex has which is safer in URLs
		# than base64 hashes.
		my $regid = md5_hex(
			(sprintf "%s%s%d", time, $user->{nickname}, int(rand 256))
		);

		# We now unregister the user, but we need to keep the ID for later.
		# Consider removal of the 'registered' flag. This state can simply
		# be determined by the presence of a non-zero length value in
		# 'reg_id'. If 'reg_id' doesn't exist, that is considered to be
		# a zero-length value.
		$slashdb->setUser($uid, {
			'registered'    => '0',
			'reg_id'        => $regid,
		});

		my $reg_msg = slashDisplay('rereg_mail', {
			# This should probably be renamed to prevent confusion.
			# But there is no real need for the CURRENT user's value
			# in this template, just the user we are expiring.
			reg_id		=> $regid,
			useradmin	=> $constants->{reg_useradmin} ||
				$constants->{adminmail},
		}, {
			Return  => 1,
			Nocomm  => 1,
			Page    => 'messages',
		});

		my $reg_subj = Slash::getData('rereg_email_subject', '', '');

		# Send the message (message code == -2)
		doEmail($uid, $reg_subj, $reg_msg, -2);
	} else {
		# We only need to clear these.
		$slashdb->setUser($uid, {
			'registered'	=> '1',
			'reg_id'	=> '',
		});
	}
}


1;

__END__


=head1 SEE ALSO

Slash(3), Slash::Utility(3).

=head1 VERSION

$Id$
