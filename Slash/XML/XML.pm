# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2001 by Open Source Development Network. See README
# and COPYING for more information, or see http://slashcode.com/.
# $Id$

package Slash::XML;

=head1 NAME

Slash::XML - Perl extension for Slash

=head1 SYNOPSIS

	use Slash::XML;
	xmlDisplay(%data);

=head1 DESCRIPTION

Slash::XML aids in creating XML.  Right now, only RSS is supported.


=head1 EXPORTED FUNCTIONS

=cut

use strict;
use Date::Manip;
use Time::Local;
use Slash;
use Slash::Utility;

use base 'Exporter';
use vars qw($VERSION @EXPORT);

($VERSION) = ' $Revision$ ' =~ /\$Revision:\s+([^\s]+)/;
@EXPORT = qw(xmlDisplay);

# FRY: There must be layers and layers of old stuff down there!

#========================================================================

=head2 xmlDisplay(TYPE, PARAM [, OPTIONS])

Creates XML data.

=over 4

=item Parameters

=over 4

=item TYPE

The XML type, which determines which XML creation routine to call.
Right now, supports only "rss" which calls create_rss().

=item PARAM

A hashref of parameters to pass to the XML creation routine.

=item OPTIONS

Hashref of options.  Currently supported options are below.
If OPTIONS is the value C<1> instead of a hashref, that will
be the same as if the hashref were C<{ Return =E<gt> 1 }>.

=over 4

=item Return

Boolean for whether to print (false) or return (true) the
processed template data.  Default is to print output via
Apache, with full HTML headers.

=back

=back

=item Return value

If OPTIONS-E<gt>{Return} is true, the XML data.
Otherwise, returns true/false for success/failure.

=back

=cut

sub xmlDisplay {
	my($type, $param, $opt) = @_;

	my $class = "Slash::XML::\U$type";
	my $file  = "Slash/XML/\U$type\E.pm";
	if (!exists($INC{$file}) && !eval("require $class")) {
		errorLog($@);
		return;
	}

	my $content = $class->create($param);
	if (!$content) {
		# I don't think we really care, actually ... do we?
# 		errorLog("$class->create returned no content");
		return;
	}

	if (! ref $opt) {
		$opt = $opt == 1 ? { Return => 1 } : {};
	}

	if ($opt->{Return}) {
		return $content;
	} else {
		my $r = Apache->request;
		$r->header_out('Cache-Control', 'private');
		$r->content_type('text/xml');
		$r->status(200);
		$r->send_http_header;
		$r->rflush;
		$r->print($content);
		$r->status(200);
		return 1;
	}
}

#========================================================================

=head2 date2iso8601([TIME])

Return a standard ISO 8601 time string.

=over 4

=item Parameters

=over 4

=item TIME

Some sort of string in GMT that can be parsed by Date::Manip.
If no TIME given, uses current time.

=back

=item Return value

The time string.

=item Dependencies

Date::Manip.

=back

=cut

sub date2iso8601 {
	my($self, $time) = @_;
	if ($time) {	# force to GMT
		$time .= ' GMT' unless $time =~ / GMT$/;
	} else {	# get current seconds
		my $t = defined $time ? 0 : time();
		$time = "epoch $t";
	}

	# calculate timezone differential from GMT
	my $diff = (timelocal(localtime) - timelocal(gmtime)) / 36;
	($diff = sprintf '%+0.4d', $diff) =~ s/(\d{2})$/:$1/;

	return scalar UnixDate($time, "%Y-%m-%dT%H:%M:%S$diff");
}

#========================================================================

=head2 encode(VALUE [, KEY])

Encodes the data to put it into the XML.  Normally will encode
assuming the parsed data will be printed in HTML.  See KEY.

=over 4

=item Parameters

=over 4

=item VALUE

Value to be encoded.

=item KEY

If KEY is "link", then data will be encoded so as NOT to assume
the parsed data will be printed in HTML.

=back

=item Return value

The encoded data.

=item Dependencies

See xmlencode() and xmlencode_plain() in Slash::Utility.

=back

=cut

sub encode {
	my($self, $value, $key) = @_;
	$key ||= '';
	my $return = $key eq 'link'
		? xmlencode_plain($value)
		: xmlencode($value);
	return $return;
}

1;

__END__

=head1 SEE ALSO

Slash(3), Slash::Utility(3), XML::Parser(3), XML::RSS(3).
