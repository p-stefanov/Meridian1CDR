#!/bin/bash
# put this in /etc/init.d/
# if ran as non-root user, ensure user is in dial-out group

# INFO 
# -tty -> serial port device file (e.g. /dev/ttyS0)
# -baudrate and -databits are for the serial port connection
# -dial_time -> seconds to subtract from the duration of a call
#    (time presumably spent dialing)
# -pricing -> JSON file containing the call-pricing information
# -initSQL -> sql code for creating the required tables

start() {
    cd ?path? && \
    ./CDR.pl -tty /dev/tty?? -baudrate ???? \
    -databits ? -dial_time ? -pricing pricing.json \
    -initSQL db/init.sql >> debug.log 2>> err.log &
    echo
}

stop() {
    pkill -f 'CDR.pl' >/dev/null 2>&1
    echo
}

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart|reload)
    stop
    start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|reload}"
    exit 1
esac
exit 0
