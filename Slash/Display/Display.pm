package Slash::Display;

=head1 NAME

Slash::Display - Display library for Slash


=head1 SYNOPSIS

	slashDisplay('some template', { key => $val });
	my $text = slashDisplay('template', \%data, 1);


=head1 DESCRIPTION

Slash::Display uses Slash::Display::Provider to provide the
template data from the Slash::DB API.

It will process and display a template using the data passed in.
In addition to whatever data is passed in the hashref, the contents
of the user, form, and static objects, as well as the %ENV hash,
are available.

C<slashDisplay> will print by default to STDOUT, but will
instead return the data if the third parameter is true.  If the fourth
parameter is true, HTML comments surrounding the template will NOT
be printed or returned.  That is, if the fourth parameter is false,
HTML comments noting the beginning and end of the template will be
printed or returned along with the template.

L<Template> for more information about templates.

=head1 EXPORTED FUNCTIONS

=cut

use strict;
use base 'Exporter';
use vars qw($REVISION $VERSION @EXPORT);
use Exporter ();
use Slash::Display::Provider;
use Slash::Utility;
use Template;

# $Id$
($REVISION)	= ' $Revision$ ' =~ /\$Revision:\s+([^\s]+)/;
($VERSION)	= $REVISION =~ /^(\d+\.\d+)/;
@EXPORT		= qw(slashDisplay);

# BENDER: Well I don't have anything else planned for today, let's get drunk!

#========================================================================

=head2 slashDisplay(NAME [, DATA, OPTIONS])

Processes a template.

=over 4

=item Parameters

=over 4

=item NAME

Can be either the name of a template block in the Slash DB,
or a reference to a scalar containing a template to be
processed.  In both cases, the template will be compiled
and the processed, unless it has previously been compiled,
in which case the cached, compiled template will be pulled
out and processed.

=item DATA

Hashref of additional parameters to pass to the template.
Default passed parameters include constants, env, user, and
form, which can be overriden (see C<_populate>).

=item OPTIONS

Hashref of options.  Currently supported options are below.
If OPTIONS is the value C<1> instead of a hashref, that will
be the same as if the hashref were C<{ Return =E<gt> 1 }>.

=over 4

=item Return

Boolean for whether to print (false) or return (true) the
processed template data.  Default is print.

=item Nocomm

Boolean for whether to include (false) or not include (true)
HTML comments surrounding template, stating what template
block this is.  Default is to include comments.

=item Section

All templates named NAME may be overriden by a template named
"SECTION_NAME" (e.g., the "header" template, may be overridden
in the "tacohell" section with a template named "tacohell_header").

By default, that section will be determined by whatever the current
section is (or "light" if the user is in light mode).  However,
the default can be overriden by the Section option.  Also, a Section
value of "NONE" will cause no section to be used.

=back

=back

=item Return value

If OPTIONS-E<gt>{Return} is true, the processed template data.
Otherwise, returns true/false for success/failure.

=item Side effects

Compiles templates and caches them.

=back

=cut

sub slashDisplay {
	# options: return, nocomm, section
	my($name, $data, $opt) = @_;
	my(@comments, $ok, $out);
	return unless $name;

	# this should be stored persistently, either for the request,
	# or for the virtual host
	my $slashdb = getCurrentDB();
	my $templates = $slashdb->getDescriptions('templates');

	# allow slashDisplay(NAME, DATA, RETURN) syntax
	if (! ref $opt) {
		$opt = $opt == 1 ? { Return => 1 } : {};
	}

	if ($opt->{Section} eq 'NONE') {
		delete $opt->{Section};
	} else {
		$opt->{Section} ||= getCurrentUser('light') ? 'light' :
			getCurrentUser('currentSection');
	}

	if (!ref $name && $opt->{Section} && exists $templates->{"$opt->{Section}_$name"}) {
		$name = "$opt->{Section}_$name";
	}

	$data ||= {};
	_populate($data);

	@comments = (
		"\n\n<!-- start template: $name -->\n\n",
		"\n\n<!-- end template: $name -->\n\n"
	);

	my $template = _template();

	if ($opt->{Return}) {
		$ok = $template->process($name, $data, \$out);
		$out = join '', $comments[0], $out, $comments[1]
			unless $opt->{Nocomm};
		
	} else {
		print $comments[0] unless $opt->{Nocomm};
		$ok = $template->process($name, $data);
		print $comments[1] unless $opt->{Nocomm};
	}

	errorLog($template->error) unless $ok;

	return $opt->{Return} ? $out : $ok;
}

=head1 PRIVATE FUNCTIONS

=cut

#========================================================================

=head2 _populate(DATA)

Put universal data stuff into each template: constants, user, form, env.
Each can be overriden by passing a hash key of the same name to
C<slashDisplay>.

=over 4

=item Parameters

=over 4

=item DATA

A hashref to be populated.

=back

=item Return value

Populated hashref.

=back

=cut

sub _populate {
	my($data) = @_;
	$data->{constants} = getCurrentStatic()
		unless exists $data->{constants};
	$data->{user} = getCurrentUser() unless exists $data->{user};
	$data->{form} = getCurrentForm() unless exists $data->{form};
	$data->{env} = { map { (lc $_, $ENV{$_}) } keys %ENV }
		unless exists $data->{env}; 
}

#========================================================================

=head2 _template()

Return a Template object.

=over 4

=item Return value

A Template object.  See L<"TEMPLATE ENVIRONMENT">.

=back

=cut

my $filters;

sub _template {
	Template->new(
		TRIM		=> 1,
		PRE_CHOMP	=> 1,
		POST_CHOMP	=> 1,
		LOAD_FILTERS	=> $filters,
		LOAD_TEMPLATES	=> [ Slash::Display::Provider->new ],
		PLUGINS		=> { Slash => 'Slash::Display::Plugin' },
	);
}

=back

=head1 TEMPLATE ENVIRONMENT

The template has the options TRIM, PRE_CHOMP, and POST_CHOMP set by default.
Its provider is Slash::Display::Provider, and the plugin module
Slash::Display::Plugin can be referenced by simply "Slash".

Additional scalar ops (which are global, so they are in effect
for every Template object created, from this or any other module)
include C<uc>, C<lc>, C<ucfirst>, and C<lcfirst>,
which all do what you think.

	[% myscalar.uc %]  # return upper case myscalar

Additional list ops include C<rand>, which returns a random element
from the given list.

	[% mylist.rand %]  # return single random element from mylist

Also provided are some filters.  The C<fixurl>, C<fixparam>, and
C<stripByMode> filters are just frontends to the functions of those
names in the Slash API:

	[% FILTER stripByMode('literal') %]
		I think that 1 > 2!
	[% END %]

	<A HREF="[% env.script_name %]?op=[% FILTER fixparam %][% form.op %][% END %]">

=cut

require Template::Filters;

my $stripByMode = sub {
	my($context, @args) = @_;
	return sub { stripByMode($_[0], @args) };
};

$filters = Template::Filters->new({
	FILTERS => {
		fixparam	=> \&fixparam,
		fixurl		=> \&fixurl,
		stripByMode	=> [ $stripByMode, 1 ]
	}
});


require Template::Stash;

my %list_ops = (
	'rand'		=> sub {
		my $list = shift;
		return $list->[rand @$list];
	}
);

my %scalar_ops = (
	'uc'		=> sub { uc $_[0] },
	'lc'		=> sub { lc $_[0] },
	'ucfirst'	=> sub { ucfirst $_[0] },
	'lcfirst'	=> sub { lcfirst $_[0] },
);

@{$Template::Stash::LIST_OPS}  {keys %list_ops}   = values %list_ops;
@{$Template::Stash::SCALAR_OPS}{keys %scalar_ops} = values %scalar_ops;

1;

__END__


=head1 AUTHOR

Chris Nandor E<lt>pudge@pobox.comE<gt>, http://pudge.net/


=head1 SEE ALSO

Template, Slash, Slash::Utility, Slash::DB, Slash::Display::Plugin.
