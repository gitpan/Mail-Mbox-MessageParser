#line 1 "inc/Module/Install/Skip.pm - /Library/Perl/5.8.1/Module/Install/Skip.pm"
package Module::Install::Skip;
use strict;

use vars qw( @ISA $VERSION );
use Module::Install::Base;
@ISA = qw(Module::Install::Base);

$VERSION = 0.01;

#line 32

sub skip
{
	my ($self, $regexp) = @_;

	my $callback = <<END;

package MY;

sub libscan
{
	my \$keeper = shift->SUPER::libscan(\@_);

	return '' if( \$keeper =~ /$regexp/ );
	return \$keeper;
};
1;
END

	eval "$callback";
	die $@ if( $@ );

	return;
}

#line 91

1;
__END__

