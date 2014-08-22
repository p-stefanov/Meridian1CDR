# Synopsis
A CDR (Call detail recording) program for the Nortel Meridian 1 PBX.

# About the program
The script is supposed start on boot as a service. For convenience, it creates a new SQLite database file for each month and fills it with call records. The model is described in 'init.sql'.

# Usage
1. Ensure that you have the following perl modules used by the script:
--* AnyEvent
--* AnyEvent::SerialPort
--* DBIx::Class
--* Getopt::Long
--* IO::Handle
--* JSON
--* Math::Round
--* Path::Class

2. Clone the repo.

3. Create a 'pricing.json' file in the main repo directory and fill it accordingly.
	Use example.pricing.json as a reference.

4. Edit service.sh and replace the question marks accordingly.

5. Copy service.sh in /etc/init.d/ and give it a name of your choice.

6. Register the script with update-rc.d and start your newly created service.
	[More info about this step here](http://manpages.ubuntu.com/manpages/hardy/man8/update-rc.d.8.html)

# Important notes
--* The call records as printed by the PBX are not standardised! Edit the regexes in the script if they don't match yours.
--* The program works on the premise that all PBX access codes are the same lenght! (Which is usualy the case)