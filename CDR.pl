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

###########################################################################
# VARS AND INFO
my ($tty, $baudrate, $databits, $access_code_lenght, $dial_time, $pricing_file, $sql_init);
my ($seconds, $price);
my %matched; # hash to save named capture buffers from the regexes
my %transfered_calls;
my $usage = q{
	-tty -> serial port device file (e.g. /dev/ttyS0)
	-baudrate and -databits are for the serial port connection
	-ac_lenght -> number of digits of the access code
	-dial_time -> seconds to subtract from the duration of a call
		(time presumably spent dialing)
	-pricing -> JSON file containing the call-pricing information
	-initSQL -> sql code for creating the required tables
};

###########################################################################
# SUBS

sub is_day {
	# my @time = split /:/, shift;
	my $time = (localtime)[2];
	return $time ge '08' && $time lt '20';
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

sub to_seconds {
	# expected string in following format \d\d:\d\d:\d\d
	return unless /^\d\d:\d\d:\d\d$/;
	my @duration = split ':';
	return $duration[0] * 3600 + $duration[1] * 60 + $duration[2];
}

# save named capture buffers from the regexes in %matched
sub save_matched {
	$matched{$_} = $+{$_} for keys %+;
	$matched{trunk} =~ s/\W//g; # remove special chars
}

# following 2 subs are at the bottom
sub calc_price;

sub update_db;

###########################################################################
# CHECK IF SCRIPT IS USED APPROPRIATELY

# disable stream buffering for both STDOUT and STDERR
STDERR->autoflush(1);
STDOUT->autoflush(1);

GetOptions ('tty=s'       => \$tty,
            'baudrate=i'  => \$baudrate,
            'databits=i'  => \$databits,
            'ac_lenght=i' => \$access_code_lenght,
            'dial_time=i' => \$dial_time,
            'pricing=s'   => \$pricing_file,
            'initSQL=s'   => \$sql_init)
	or die "Error in command line arguments\n";

for ($tty, $baudrate, $databits, $access_code_lenght, $dial_time, $pricing_file, $sql_init) {
	die "Not all args specified!\n$usage" unless defined;
}

die "$pricing_file does not exist!\n" unless (-f $pricing_file);
die "$sql_init does not exist!\n" unless (-f $sql_init);
die "db directory does not exist!\n" unless (-d 'db');

###########################################################################
# LOAD PRICING INFO

# get info from pricing file
local $/;
open( my $fh, '<', $pricing_file ) or die $!;

my $json = JSON->new->allow_nonref;
$json = $json->relaxed([1]); # for trailing commas
my $json_ref = $json->decode( <$fh> );
close $fh;

###########################################################################
# DB SETUP

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


###########################################################################
# EVENT HANDLER
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
			###########################################################################
			# MAIN LOGIC OF SCRIPT

			my ($hdl, $line) = @_;
			say $line if $line =~ /^[NSE] /;

			if ($line =~ qr{
				^[NS]\s\d{3}\s\d\d\s
				(?<dn>\d{1,6})\s+
				(?<trunk>T\d{3}.\d{3})\s
				(?<date>\d\d/\d\d)\s
				(?<time>\d\d:\d\d)\s
				(?<duration>\d\d:\d\d:\d\d)\s+A?\s*
				(?<number>\d+)
			}x) {
				save_matched();
				$seconds = to_seconds( $matched{duration} );

				if ($line =~ /^N/) { # N stands for normal call type, i.e. not transfered
					$seconds -= $dial_time;
					$price = calc_price();
					return if $price == 0;
					update_db('N');	
				} else { # the call has been transfered
					$transfered_calls{ $matched{trunk} } = {
						number => $matched{number},
						seconds => $seconds
					}; 
				}	
			} elsif ($line =~ qr{
				^E\s\d{3}\s\d\d\s
				(?<trunk>T\d{3}.\d{3})\s
				(?<dn>\d{1,6})\s+
				(?<date>\d\d/\d\d)\s
				(?<time>\d\d:\d\d)\s
				(?<duration>\d\d:\d\d:\d\d)
			}x) { # ?<number> is missing in the regex => $matched{number} needs to be set
				save_matched();
				$seconds = to_seconds( $matched{duration} );

				if ($transfered_calls{ $matched{trunk} }) {
					$seconds += $transfered_calls{ $matched{trunk} }{seconds} - $dial_time;
					# $matched{number} is set
					$matched{number} = $transfered_calls{ $matched{trunk} }{number};
					$price = calc_price();
					return if $price == 0;
					update_db('');
					delete $transfered_calls{ $matched{trunk} };
				}
			}
		});
	},
	# other AnyEvent::Handle arguments here
);

$cv->recv;

###########################################################################
# SUBS IMPLEMENTATION
sub calc_price {
	my $called = substr($matched{number}, $access_code_lenght);

	return 0 if $seconds <= 0;

	for my $i (keys %$json_ref) {
		if ($matched{trunk} =~ qr/^$i/) {
			for my $j (keys $$json_ref{$i}) {
				if ($called =~ qr/^$j/) {
					if (is_day()) {
						return nearest( .01, $$json_ref{$i}{$j}[0]
							+ $$json_ref{$i}{$j}[1] * ($seconds / 60) );
					}
					return nearest( .01, $$json_ref{$i}{$j}[0]
						+ $$json_ref{$i}{$j}[2] * ($seconds / 60) );
				}
			}
			# if we are here - take default values
			# (they must be defined in the pricing file)
			if (is_day()) {
				return nearest( .01, $$json_ref{$i}{default}[0]
					+ $$json_ref{$i}{default}[1] * ($seconds / 60) );
			}
			return nearest( .01, $$json_ref{$i}{default}[0]
				+ $$json_ref{$i}{default}[2] * ($seconds / 60) );
		}
	}
	# if we are here => trunk key is not found in pricing file (should not happen)
	print STDERR "$matched{trunk} key not found in $pricing_file\n";
	return 0;
}

sub update_db {
	my $database = this_month();
	my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$database.db");
	my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

	my $user = $schema->resultset('User')->find_or_new({
		dn => $matched{dn},
	});
	$user->callscount($user->callscount + 1);
	$user->bill($user->bill + $price);
	$user->seconds($user->seconds + $seconds);
	$user->insert_or_update;

	$schema->resultset('Call')->create({
		dn => $matched{dn},
		trunk => $matched{trunk},
		seconds => $seconds,
		date => scalar localtime,
		called => $matched{number},
		price => $price,
		type => shift
	});
}