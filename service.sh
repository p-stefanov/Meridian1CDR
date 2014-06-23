#!/bin/bash
start() {
        cd <path>
        ./serial.listener.DBIx.pl -tty /dev/ttyS0 -baudrate 1200 \
        -databits 7 -chomp 3 -seconds 10 -pricing pricing.json \
        -initSQL db/init.sql >/dev/null 2>> err.log &
	echo
}

stop() {
	kill -9 `pidof perl serial.listener.DBIx.pl`
	echo
}

case "$1" in
  start)
	start
	;;
  stop)
	stop
	;;
  restart|reload|condrestart)
	stop
	start
	;;
  *)
	echo "Usage: $0 {start|stop|restart|reload}"
	exit 1
esac
exit 0

