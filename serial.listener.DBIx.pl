#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::SerialPort;
use Meridian::Schema;
use 5.010;

use Path::Class 'file';
my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file('db/calls.db');

my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

my $cv = AnyEvent->condvar;
my $hdl; $hdl = AnyEvent::SerialPort->new(
	serial_port =>
		[ '/dev/ttyUSB0',
			[ baudrate => 1200 ],
			[ databits => 7 ],
			# other [ "Device::SerialPort setter name" => \@arguments ] here
		],
	on_error => sub {
		my ($hdl, $fatal, $msg) = @_;
		AE::log error => $msg;
		$hdl->destroy;
		$cv->send;
	},
	on_read => sub {
		my ($hdl) = @_;
		$hdl->push_read (line => sub {
			my ($hdl, $line) = @_;
			# say $line;
			if ($line =~ qr/
					^[NE]\s\d{3}\s\d{2}\s
					(?<dn>\d{2,6})\s+
					(?<trunk>\w+).{13}
					(?<date>\d\d\/\d\d)\s+
					(?<time>\d\d:\d\d)\s+
					(?<duration>\d\d:\d\d:\d\d)\s+A*\s*
					(?<number>\d+)
				/x) {
				say "Call from $+{dn} through trunk $+{trunk} on $+{date} at $+{time}, lasted $+{duration}, to $+{number}";
				my @duration = split(':', $+{duration});
				my $seconds = $duration[0] * 3600 + $duration[1] * 60 + $duration[2];
				my $time = ((localtime)[5] + 1900) . '-' . join '-', split '/', $+{date} . ' ' . $+{time};
				my $user = $schema->resultset('User')->find_or_new({
					dn => $+{dn},
				});
				$schema->resultset('Call')->create({
					user => $+{dn},
					trunk => $+{trunk},
					seconds => $seconds,
					date => $time,
					called => $+{number},
				});
				{
					no warnings 'uninitialized';
					$user->callscount($user->callscount + 1);
					$user->seconds($user->seconds + $seconds);
				}
				$user->insert_or_update;
			}
		});
	},
	# other AnyEvent::Handle arguments here
);

$cv->recv;
