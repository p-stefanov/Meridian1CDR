package Meridian::Schema::Result::User;

use warnings;
use strict;

use base qw( DBIx::Class::Core );

__PACKAGE__->table('user');

__PACKAGE__->add_columns(
	dn => {
		data_type => 'integer',
	},
	callscount => {
		data_type => 'integer',
	},
	seconds => {
		data_type => 'integer',
	},
);

__PACKAGE__->set_primary_key('dn');
__PACKAGE__->has_many('calls' => 'Meridian::Schema::Result::Call', 'dn');

sub new {
	my ( $class, $attrs ) = @_;

	$attrs->{ 'callscount' } ||= 0;
	$attrs->{ 'seconds' } ||= 0;

	return $class->next::method( $attrs );
}

1;
