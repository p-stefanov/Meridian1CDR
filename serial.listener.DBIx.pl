#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::SerialPort;
use Meridian::Schema;
use 5.010;

use Path::Class 'file';

my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

my $initSQL = q/create table if not exists user
(
dn integer not null PRIMARY KEY,
callscount integer not null,
seconds integer not null
);

create table if not exists call
(
callid integer not null PRIMARY KEY,
dn integer not null,
seconds integer not null,
trunk text not null,
date text not null,
called text not null,
FOREIGN KEY(dn) REFERENCES user(dn)
);
/;

# on startup check if db for this month exists and if not - create it
my $dbName = $months[(localtime)[4]] . '-' . ((localtime)[5] + 1900);
unless (-e "db/$dbName.db") {
	system("sqlite3 db/$dbName.db '$initSQL'") == 0 or print STDERR $!;
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
			system("sqlite3 db/$dbName.db '$initSQL'") == 0 or print STDERR $!;
			say "file created for NEXT month";
		}
	}
);

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
				my $dbName = $months[(localtime)[4]] . '-' . ((localtime)[5] + 1900);
				my $db_fn = file($INC{'Meridian/Schema.pm'})->dir->parent->file("db/$dbName.db");
				my $schema = Meridian::Schema->connect("dbi:SQLite:$db_fn");

				say "$+{dn} calling $+{number} through $+{trunk} on $+{date} at $+{time}, lasting $+{duration} sec.";
				my @duration = split(':', $+{duration});
				my $seconds = $duration[0] * 3600 + $duration[1] * 60 + $duration[2];
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
				});
				$user->callscount($user->callscount + 1);
				$user->seconds($user->seconds + $seconds);
				$user->insert_or_update;
			}
		});
	},
	# other AnyEvent::Handle arguments here
);

$cv->recv;
