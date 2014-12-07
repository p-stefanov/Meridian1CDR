# About the program
The script is supposed start on boot as a service. For convenience, it creates a new sqlite3 database file for each month and fills it with call records. The model is described in 'db/init.sql'.

# Requirements
1. The following perl modules:
	* AnyEvent
	* AnyEvent::SerialPort
	* DBIx::Class
	* Getopt::Long
	* IO::Handle
	* JSON
	* Math::Round
	* Modern::Perl
	* Log::Log4perl
	* Path::Class

2. SQLite version 3

# Deployment
1. Clone the repo.

2. Create a 'pricing.json' file in the main repo directory and fill it accordingly.
	Use example.pricing.json as a reference.

3. Edit 'service.sh' and replace the question marks accordingly.

4. Copy 'service.sh' in /etc/init.d/ and give it a name of your choice.

5. Register the script with update-rc.d and start your newly created service.
	More info about this step [here](http://manpages.ubuntu.com/manpages/hardy/man8/update-rc.d.8.html)
