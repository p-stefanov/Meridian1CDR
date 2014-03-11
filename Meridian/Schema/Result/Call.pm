package Meridian::Schema::Result::Call;

use warnings;
use strict;

use base qw( DBIx::Class::Core );

__PACKAGE__->table('call');

__PACKAGE__->add_columns(
	callid => {
		data_type => 'integer',
		is_auto_increment => 1
	},
	dn => {
		data_type => 'integer',
	},
	seconds => {
		data_type => 'integer',
	},
	trunk => {
		data_type => 'text',
	},
	date => {
		data_type => 'datetime',
	},
	called => {
		data_type => 'text',
	},
	price => {
		data_type => 'real',
	},
);

__PACKAGE__->set_primary_key('callid');
__PACKAGE__->belongs_to('user' => 'Meridian::Schema::Result::User', 'dn');

1;
