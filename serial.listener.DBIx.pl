#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::SerialPort;
use JSON;
use Meridian::Schema;
use Math::Round 'nearest';
use Path::Class 'file';
use 5.010;

my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub calc_price;
sub is_day;

# get info from json file
local $/;
open( my $fh, '<', 'pricing.json' ) or die $!;

my $json = JSON->new->allow_nonref;
$json = $json->relaxed([1]);
my $json_ref = $json->decode( <$fh> );

# on startup check if db for this month exists and if not - create it
my $dbName = $months[(localtime)[4]] . '-' . ((localtime)[5] + 1900);
unless (-e "db/$dbName.db") {
	system("sqlite3 db/$dbName.db < db/init.sql") == 0 or die $!;
	say "file created for THIS month";
}

my $cv = AnyEvent->condvar;

# timer to check every 27 days if db for next month exist and if not - create it
my $w = AnyEvent->timer(
	after => 0,
	interval => 27 * 24 * 60 * 60,
	cb => sub {
		# + 1 stands for next month ..........\/
		my $dbName = $months[((localtime)[4] + 1) % 12] . '-' . ((localtime)[5] + 1900);
		unless (-e "db/$dbName.db") {
			system("sqlite3 db/$dbName.db < db/init.sql") == 0 or die $!;
			say "file created for NEXT month";
		}
	}
);

my $hdl; $hdl = AnyEvent::SerialPort->new(
	serial_port =>
		# could also be ttyS0 for example
		[ '/dev/ttyUSB0',
			# other values here possible
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
				my @duration = split(':', $+{duration});
				my $seconds = $duration[0] * 3600 + $duration[1] * 60 + $duration[2];

				# !! designed for specific place -> substr ... , 2 (could be 3 or not fixed at all)
				# also -> subtract some number from $seconds

				my $price = calc_price( $json_ref, substr($+{number}, 2), $+{trunk}, $seconds, $+{time} );

				return if $price == 0;

				my $dbName = $months[(localtime)[4]] . '-' . ((localtime)[5] + 1900);
				my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$dbName.db");
				my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

				say "$+{dn} calling $+{number} through $+{trunk} on $+{date} at $+{time}, lasting $+{duration} sec, price: $price.";
				my $time = ((localtime)[5] + 1900) . '-' . join '-', split '/', $+{date} . ' ' . $+{time};

				my $user = $schema->resultset('User')->find_or_new({
					dn => $+{dn},
				});

				$schema->resultset('Call')->create({
					dn => $+{dn},
					trunk => $+{trunk},
					seconds => $seconds,
					date => $time,
					called => $+{number},
					price => $price,
				});
				$user->callscount($user->callscount + 1);
				$user->bill($user->bill + $price);
				$user->seconds($user->seconds + $seconds);
				$user->insert_or_update;
			}
		});
	},
	# other AnyEvent::Handle arguments here
);

$cv->recv;

sub calc_price {
	my ($json_ref, $called, $trunk, $seconds, $time) = @_;
	return 0 if $seconds <= 0;
	for my $i (keys %$json_ref) {
		if ($trunk =~ qr/^$i/) {
			for my $j (keys $$json_ref{$i}) {
				if ($called =~ qr/^$j/) {
					if (is_day($time)) {
						return nearest( .01, $$json_ref{$i}{$j}[0] + $$json_ref{$i}{$j}[1] * ($seconds / 60) );
					}
					return nearest( .01, $$json_ref{$i}{$j}[0] + $$json_ref{$i}{$j}[2] * ($seconds / 60) );
				}
			}
			# if we are here - take default values (they must be defined in the json file)
			if (is_day($time)) {
				return nearest( .01, $$json_ref{$i}{default}[0] + $$json_ref{$i}{default}[1] * ($seconds / 60) );
			}
			return nearest( .01, $$json_ref{$i}{default}[0] + $$json_ref{$i}{default}[2] * ($seconds / 60) );
		}
	}
	# if we are here => trunk key is not found in json file (should not happen)
	print STDERR "trunk key not found in json file\n";
	return 0;
}

sub is_day {
	my @time = split /:/, shift;
	return $time[0] ge '08' && $time[0] lt '20';
}