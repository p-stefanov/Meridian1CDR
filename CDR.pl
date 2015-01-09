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
use Time::localtime;

###########################################################################
# GLOBALS AND INFO

our $Logger = Log::Log4perl->get_logger(__PACKAGE__);
use vars qw/
	$Tty
	$Baudrate
	$Databits
	$Dial_Time
	$Pricing_File
	$Sql_Init
	$Seconds
	$Price
	%Matched
	%Transfered_Calls
	$Json_Ref
/;
# %Matched is used to save capture groups from the regexes

###########################################################################
# SUBS

sub usage {
	print STDERR "Error: @_\n" if @_;
	print STDERR <<USAGE;
Usage: $0 [options]
Options:
  -tty                serial port device file (e.g. /dev/ttyS0)
  -baudrate
  -databits
  -dial_time          seconds to subtract from the duration of a call
                      (time presumably spent dialing)
  -pricing            JSON file containing the call-pricing information
  -initSQL            sql code for creating the required tables
USAGE
	exit(2);
}

sub is_day {
	# my @time = split /:/, shift;
	my $time = localtime->hour;
	return $time >= 8 && $time < 20;
}

sub this_month {
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	return $months[localtime->mon] . '-' . (localtime->year + 1900);
}

sub next_month {
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	if (localtime->mon == 11) { # it's Dec => next month is Jan of next year!
		return $months[0] . '-' . (localtime->year + 1901);
	}
	return $months[localtime->mon + 1] . '-' . (localtime->year + 1900);
}

sub to_seconds {
	# expected string in following format \d\d:\d\d:\d\d
	my @duration = split ':', shift;
	return $duration[0] * 3600 + $duration[1] * 60 + $duration[2];
}

# save named capture buffers from the regexes in %Matched
sub save_matched {
	$Matched{$_} = $+{$_} for keys %+;
	$Matched{trunk} =~ s/\W//g; # remove special chars
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

GetOptions ('tty=s'       => \$Tty,
            'baudrate=i'  => \$Baudrate,
            'databits=i'  => \$Databits,
            'dial_time=i' => \$Dial_Time,
            'pricing=s'   => \$Pricing_File,
            'initSQL=s'   => \$Sql_Init)
	or usage( "bad option" );

$Logger->logdie( "$Pricing_File does not exist!" ) unless (-f $Pricing_File);
$Logger->logdie( "$Sql_Init does not exist!" ) unless (-f $Sql_Init);

###########################################################################
# LOAD PRICING INFO

# get info from pricing file
local $/;
open( my $fh, '<', $Pricing_File ) or $Logger->logdie( $! );

my $json = JSON->new->allow_nonref;
$json = $json->relaxed([1]); # for trailing commas
$Json_Ref = $json->decode( <$fh> );
close $fh;

###########################################################################
# DB SETUP

# on startup check if db for this month exists and if not - create it
my $dbName = this_month();
unless (-e "db/$dbName.db") {
	system("sqlite3 db/$dbName.db < $Sql_Init") == 0 or $Logger->logdie( $! );
	$Logger->info( "file created for THIS month" );
}

# timer to check every 27 days if db for next month exist and if not - create it
my $w = AnyEvent->timer(
	after => 0,
	interval => 27 * 24 * 60 * 60,
	cb => sub {
		my $database = next_month();
		unless (-e "db/$database.db") {
			system("sqlite3 db/$database.db < $Sql_Init") == 0 or $Logger->logdie( $! );
			$Logger->info( "file created for NEXT month" );
		}
	}
);


###########################################################################
# EVENT HANDLER
my $cv = AnyEvent->condvar;
my $hdl; $hdl = AnyEvent::SerialPort->new(
	serial_port =>
		[ $Tty,
			[ baudrate => $Baudrate ],
			[ databits => $Databits ],
			# other [ "Device::SerialPort setter name" => \@arguments ] here
		],
	on_error => sub {
		my ($hdl, $fatal, $msg) = @_;
		$Logger->fatal( $fatal ) if $fatal;
		$Logger->error( $msg );
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
	$Logger->trace( "PBX says: " . $line );
	$Logger->debug( "CDR line: " . $line ) if $line =~ /^[NSE] /;

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
		$Seconds = to_seconds( $Matched{duration} );

		if ($line =~ /^N/) { # N stands for normal call type, i.e. not transfered
			$Seconds -= $Dial_Time;
			if ($Seconds <= 0) {
				$Logger->info( "seconds - dial_time <= 0: $line" );
				return;
			}
			$Price = calc_price();
			if ($Price == 0) {
				$Logger->info( "price = 0: $line" );
				return;
			}

			update_db('N');

		} else { # the call has been transfered
			$Transfered_Calls{ $Matched{trunk} } = {
				number => $Matched{number},
				seconds => $Seconds
			};
		}
	} elsif ($line =~ qr{
		^E\s\d{3}\s\d\d\s
		(?<trunk>T\d{3}.\d{3})\s
		(?<dn>\d{1,6})\s+
		(?<date>\d\d/\d\d)\s
		(?<time>\d\d:\d\d)\s
		(?<duration>\d\d:\d\d:\d\d)
	}x) { # ?<number> is missing in the regex => $Matched{number} needs to be set
		save_matched();
		$Seconds = to_seconds( $Matched{duration} );

		if ($Transfered_Calls{ $Matched{trunk} }) {
			$Seconds += $Transfered_Calls{ $Matched{trunk} }{seconds} - $Dial_Time;
			if ($Seconds <= 0) {
				$Logger->info( "seconds - dial_time <= 0: $line" );
				return;
			}
			# $Matched{number} is set
			$Matched{number} = $Transfered_Calls{ $Matched{trunk} }{number};
			$Price = calc_price();
			if ($Price == 0) {
				$Logger->info( "price = 0: $line" );
				return;
			}

			update_db('E');

			undef $Transfered_Calls{ $Matched{trunk} };
		}
	}
}


sub calc_price {
	$Logger->debug( "calculating price for number: " . $Matched{number} );
	my $called = $Matched{number};
	for my $access_code (@{ $$Json_Ref{'access_codes'} }) {
		last if $called =~ s/^$access_code//;
	}

	return 0 if length $called < 3;

	if ($called eq $Matched{number}) {
		$Logger->error("No access code matched for $called");
		return 0;
	}

	for my $i (keys %$Json_Ref) {
		if ($Matched{trunk} =~ qr/^$i/) {
			$Logger->debug( 'Trunk ' . $Matched{trunk} . ' matched ' . "^$i" );
			for my $j (keys $$Json_Ref{$i}) {
				if ($called =~ qr/^$j/) {
					$Logger->debug( 'Number ' . $called . ' matched ' . "^$j" );
					return nearest( .01, $$Json_Ref{$i}{$j}[0]
						+ $$Json_Ref{$i}{$j}[is_day() ? 1 : 2] * ($Seconds / 60) );
				}
			}
			# if we are here - take default values
			# (they must be defined in the pricing file)
			$Logger->debug( "taking default values for number $Matched{number}, trunk $Matched{trunk}" );
			return nearest( .01, $$Json_Ref{$i}{default}[0]
				+ $$Json_Ref{$i}{default}[is_day() ? 1 : 2] * ($Seconds / 60) );
		}
	}
	# if we are here => trunk key is not found in pricing file (should not happen)
	$Logger->error( "$Matched{trunk} key not found in $Pricing_File" );
	return 0;
}

sub update_db {
	my $database = this_month();
	my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$database.db");
		my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

	my $user = $schema->resultset('User')->find_or_new({
		dn => $Matched{dn},
	});
	$user->callscount($user->callscount + 1);
	$user->bill($user->bill + $Price);
	$user->seconds($user->seconds + $Seconds);
	$user->insert_or_update;

	$schema->resultset('Call')->create({
		dn      => $Matched{dn},
		trunk   => $Matched{trunk},
		seconds => $Seconds,
		date    => ctime(),
		called  => $Matched{number},
		price   => $Price,
		type    => shift
	});
}
