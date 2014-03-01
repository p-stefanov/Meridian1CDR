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
		# default_value => 0, #nope
	},
	seconds => {
		data_type => 'integer',
		# default_value => 0, #nope
	},
);

__PACKAGE__->set_primary_key('dn');
__PACKAGE__->has_many('calls' => 'Meridian::Schema::Result::Call');

1;
