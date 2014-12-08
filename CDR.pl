#!/usr/bin/env perl

BEGIN {
	require Log::Log4perl;
	Log::Log4perl->init( 'log.conf' );
}

use AnyEvent;
use AnyEvent::SerialPort;
use Getopt::Long;
use IO::Handle;
use JSON;
use Math::Round 'nearest';
use Meridian::Schema;
use Modern::Perl '2010';
use Path::Class 'file';

###########################################################################
# GLOBALS AND INFO

our $logger = Log::Log4perl->get_logger(__PACKAGE__);
use vars qw/
	$TTY
	$BAUDRATE
	$DATABITS
	$DIAL_TIME
	$PRICING_FILE
	$SQL_INIT
	$SECONDS
	$PRICE
	%MATCHED
	%TRANSFERED_CALLS
	$USAGE
	$JSON_REF
/;
# %MATCHED is used to save capture groups from the regexes
$USAGE = q{
	-tty -> serial port device file (e.g. /dev/ttyS0)
	-baudrate and -databits are for the serial port connection
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
	my @duration = split ':', shift;
	return $duration[0] * 3600 + $duration[1] * 60 + $duration[2];
}

# save named capture buffers from the regexes in %MATCHED
sub save_matched {
	$MATCHED{$_} = $+{$_} for keys %+;
	$MATCHED{trunk} =~ s/\W//g; # remove special chars
}

# following 3 subs are at the bottom
sub calc_price;

sub update_db;

sub process;

###########################################################################
# CHECK IF SCRIPT IS USED APPROPRIATELY

# disable stream buffering for both STDOUT and STDERR
STDERR->autoflush(1);
STDOUT->autoflush(1);

GetOptions ('tty=s'       => \$TTY,
            'baudrate=i'  => \$BAUDRATE,
            'databits=i'  => \$DATABITS,
            'dial_time=i' => \$DIAL_TIME,
            'pricing=s'   => \$PRICING_FILE,
            'initSQL=s'   => \$SQL_INIT)
	or $logger->logdie( "Error in command line arguments" );

for ($TTY, $BAUDRATE, $DATABITS, $DIAL_TIME, $PRICING_FILE, $SQL_INIT) {
	$logger->logdie( "Not all args specified!\n$USAGE" ) unless defined;
}

$logger->logdie( "$PRICING_FILE does not exist!" ) unless (-f $PRICING_FILE);
$logger->logdie( "$SQL_INIT does not exist!" ) unless (-f $SQL_INIT);

###########################################################################
# LOAD PRICING INFO

# get info from pricing file
local $/;
open( my $fh, '<', $PRICING_FILE ) or $logger->logdie( $! );

my $json = JSON->new->allow_nonref;
$json = $json->relaxed([1]); # for trailing commas
$JSON_REF = $json->decode( <$fh> );
close $fh;

###########################################################################
# DB SETUP

# on startup check if db for this month exists and if not - create it
my $dbName = this_month();
unless (-e "db/$dbName.db") {
	system("sqlite3 db/$dbName.db < $SQL_INIT") == 0 or $logger->logdie( $! );
	$logger->info( "file created for THIS month" );
}

# timer to check every 27 days if db for next month exist and if not - create it
my $w = AnyEvent->timer(
	after => 0,
	interval => 27 * 24 * 60 * 60,
	cb => sub {
		my $database = next_month();
		unless (-e "db/$database.db") {
			system("sqlite3 db/$database.db < $SQL_INIT") == 0 or $logger->logdie( $! );
			$logger->info( "file created for NEXT month" );
		}
	}
);


###########################################################################
# EVENT HANDLER
my $cv = AnyEvent->condvar;
my $hdl; $hdl = AnyEvent::SerialPort->new(
	serial_port =>
		[ $TTY,
			[ baudrate => $BAUDRATE ],
			[ databits => $DATABITS ],
			# other [ "Device::SerialPort setter name" => \@arguments ] here
		],
	on_error => sub {
		my ($hdl, $fatal, $msg) = @_;
		$logger->fatal( $fatal ) if $fatal;
		$logger->error( $msg );
		$hdl->destroy;
		$cv->send;
	},
	on_read => sub {
		my ($hdl) = @_;
		$hdl->push_read (line => \&process);
	}
	# other AnyEvent::Handle arguments here
);


$cv->recv;


###########################################################################
# SUBS IMPLEMENTATION

sub process {
##### MAIN LOGIC OF THE SCRIPT
	my ($hdl, $line) = @_;
	$logger->trace( "PBX says: " . $line );
	$logger->debug( "CDR line: " . $line ) if $line =~ /^[NSE] /;

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
		$SECONDS = to_seconds( $MATCHED{duration} );

		if ($line =~ /^N/) { # N stands for normal call type, i.e. not transfered
			$SECONDS -= $DIAL_TIME;
			if ($SECONDS <= 0) {
				$logger->info( "seconds - dial_time <= 0: $line" );
				return;
			}
			$PRICE = calc_price();
			if ($PRICE == 0) {
				$logger->info( "price = 0: $line" );
				return;
			}

			update_db('N');

		} else { # the call has been transfered
			$TRANSFERED_CALLS{ $MATCHED{trunk} } = {
				number => $MATCHED{number},
				seconds => $SECONDS
			};
		}
	} elsif ($line =~ qr{
		^E\s\d{3}\s\d\d\s
		(?<trunk>T\d{3}.\d{3})\s
		(?<dn>\d{1,6})\s+
		(?<date>\d\d/\d\d)\s
		(?<time>\d\d:\d\d)\s
		(?<duration>\d\d:\d\d:\d\d)
	}x) { # ?<number> is missing in the regex => $MATCHED{number} needs to be set
		save_matched();
		$SECONDS = to_seconds( $MATCHED{duration} );

		if ($TRANSFERED_CALLS{ $MATCHED{trunk} }) {
			$SECONDS += $TRANSFERED_CALLS{ $MATCHED{trunk} }{seconds} - $DIAL_TIME;
			if ($SECONDS <= 0) {
				$logger->info( "seconds - dial_time <= 0: $line" );
				return;
			}
			# $MATCHED{number} is set
			$MATCHED{number} = $TRANSFERED_CALLS{ $MATCHED{trunk} }{number};
			$PRICE = calc_price();
			if ($PRICE == 0) {
				$logger->info( "price = 0: $line" );
				return;
			}

			update_db('E');

			undef $TRANSFERED_CALLS{ $MATCHED{trunk} };
		}
	}
}


sub calc_price {
	$logger->debug( "calculating price for number: " . $MATCHED{number} );
	my $called = $MATCHED{number};
	for my $access_code (@{ $$JSON_REF{'access_codes'} }) {
		last if $called =~ s/^$access_code//;
	}

	return 0 if length $called < 3;

	if ($called eq $MATCHED{number}) {
		$logger->error("No access code matched for $called");
		return 0;
	}

	for my $i (keys %$JSON_REF) {
		if ($MATCHED{trunk} =~ qr/^$i/) {
			$logger->debug( 'Trunk ' . $MATCHED{trunk} . ' matched ' . "^$i" );
			for my $j (keys $$JSON_REF{$i}) {
				if ($called =~ qr/^$j/) {
					$logger->debug( 'Number ' . $called . ' matched ' . "^$j" );
					return nearest( .01, $$JSON_REF{$i}{$j}[0]
						+ $$JSON_REF{$i}{$j}[is_day() ? 1 : 2] * ($SECONDS / 60) );
				}
			}
			# if we are here - take default values
			# (they must be defined in the pricing file)
			$logger->debug( "taking default values for number $MATCHED{number}, trunk $MATCHED{trunk}" );
			return nearest( .01, $$JSON_REF{$i}{default}[0]
				+ $$JSON_REF{$i}{default}[is_day() ? 1 : 2] * ($SECONDS / 60) );
		}
	}
	# if we are here => trunk key is not found in pricing file (should not happen)
	$logger->error( "$MATCHED{trunk} key not found in $PRICING_FILE" );
	return 0;
}

sub update_db {
	my $database = this_month();
	my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$database.db");
        my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

	my $user = $schema->resultset('User')->find_or_new({
		dn => $MATCHED{dn},
	});
	$user->callscount($user->callscount + 1);
	$user->bill($user->bill + $PRICE);
	$user->seconds($user->seconds + $SECONDS);
	$user->insert_or_update;

	$schema->resultset('Call')->create({
		dn      => $MATCHED{dn},
		trunk   => $MATCHED{trunk},
		seconds => $SECONDS,
		date    => scalar localtime,
		called  => $MATCHED{number},
		price   => $PRICE,
		type    => shift
	});
}
