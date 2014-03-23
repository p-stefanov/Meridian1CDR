#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::SerialPort;
use Getopt::Long;
use IO::Handle;
use JSON;
use Meridian::Schema;
use Math::Round 'nearest';
use Path::Class 'file';
use 5.010;

# disable stream buffering for both STDOUT and STDERR
STDERR->autoflush(1);
STDOUT->autoflush(1);

sub is_day {
	my @time = split /:/, shift;
	return $time[0] ge '08' && $time[0] lt '20';
}

sub this_month {
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	return $months[(localtime)[4]] . '-' . ((localtime)[5] + 1900);
}

sub next_month {
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	if ((localtime)[4] == 11) { # it's Dec => next month is Jan of next year!
		return $months[0] . '-' . ((localtime)[5] + 1901);
	}
	return $months[(localtime)[4] + 1] . '-' . ((localtime)[5] + 1900);
}

sub calc_price; # at bottom of file


my ($tty, $baudrate, $databits, $chomp, $subtract, $pricing_file, $sql_init);
my $INFO = q{
	tty -> device file name (for the serial port)
	baudrate and databits are for the serial port connection
	chomp -> number of digits of the access code
	seconds -> seconds to subtract from duration of a call
	pricing -> JSON file containing the call-pricing information
	initSQL -> sql code for creating the required tables
};
GetOptions ('tty=s'      => \$tty,
			'baudrate=i' => \$baudrate,
			'databits=i' => \$databits,
			'chomp=i'    => \$chomp,
			'seconds=i'  => \$subtract,
			'pricing=s'  => \$pricing_file,
			'initSQL=s'  => \$sql_init)
	or die "Error in command line arguments\n";

for ($tty, $baudrate, $databits, $chomp, $subtract, $pricing_file, $sql_init) {
	die "Define all args: -tty, -baudrate, -databits, -chomp, -seconds, -pricing, -initSQL!\nArgs info: $INFO"
	unless defined;
}

die "$pricing_file does not exist!\n" unless (-f $pricing_file);
die "$sql_init does not exist!\n" unless (-f $sql_init);
die "db directory does not exist!\n" unless (-d 'db');


# get info from pricing file
local $/;
open( my $fh, '<', $pricing_file ) or die $!;

my $json = JSON->new->allow_nonref;
$json = $json->relaxed([1]); # for trailing commas
my $json_ref = $json->decode( <$fh> );
close $fh;

# on startup check if db for this month exists and if not - create it
my $dbName = this_month();
unless (-e "db/$dbName.db") {
	system("sqlite3 db/$dbName.db < $sql_init") == 0 or die $!;
	say "file created for THIS month";
}

my $cv = AnyEvent->condvar;

# timer to check every 27 days if db for next month exist and if not - create it
my $w = AnyEvent->timer(
	after => 0,
	interval => 27 * 24 * 60 * 60,
	cb => sub {
		my $database = next_month();
		unless (-e "db/$database.db") {
			system("sqlite3 db/$database.db < $sql_init") == 0 or die $!;
			say "file created for NEXT month";
		}
	}
);

my $hdl; $hdl = AnyEvent::SerialPort->new(
	serial_port =>
		[ $tty,
			[ baudrate => $baudrate ],
			[ databits => $databits ],
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

				# $chomp specifies the number of digits we need to remove from beginning of called number
				# $subtract -> seconds to subtract from duration (time spent dialing)
				my $price = calc_price( $json_ref, substr($+{number}, $chomp), $+{trunk}, $seconds - $subtract, $+{time} );

				return if $price == 0;

				my $database = this_month();
				my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$database.db");
				my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

				say qq/$+{dn} calling $+{number} through $+{trunk} on $+{date}
					at $+{time}, lasting $+{duration} sec, price: $price./;
				my $time = ((localtime)[5] + 1900) . '-' . join '-', split '/', $+{date} . ' ' . $+{time};

				my $user = $schema->resultset('User')->find_or_new({
					dn => $+{dn},
				});
				$user->callscount($user->callscount + 1);
				$user->bill($user->bill + $price);
				$user->seconds($user->seconds + $seconds);
				$user->insert_or_update;

				$schema->resultset('Call')->create({
					dn => $+{dn},
					trunk => $+{trunk},
					seconds => $seconds,
					date => $time,
					called => $+{number},
					price => $price,
				});
			}
		});
	},
	# other AnyEvent::Handle arguments here
);

$cv->recv;

sub calc_price {
	my ($href, $called, $trunk, $seconds, $time) = @_;
	return 0 if $seconds <= 0;
	for my $i (keys %$href) {
		if ($trunk =~ qr/^$i/) {
			for my $j (keys $$href{$i}) {
				if ($called =~ qr/^$j/) {
					if (is_day($time)) {
						return nearest( .01, $$href{$i}{$j}[0] + $$href{$i}{$j}[1] * ($seconds / 60) );
					}
					return nearest( .01, $$href{$i}{$j}[0] + $$href{$i}{$j}[2] * ($seconds / 60) );
				}
			}
			# if we are here - take default values (they must be defined in the pricing file)
			if (is_day($time)) {
				return nearest( .01, $$href{$i}{default}[0] + $$href{$i}{default}[1] * ($seconds / 60) );
			}
			return nearest( .01, $$href{$i}{default}[0] + $$href{$i}{default}[2] * ($seconds / 60) );
		}
	}
	# if we are here => trunk key is not found in pricing file (should not happen)
	print STDERR "$trunk key not found in $pricing_file\n";
	return 0;
}