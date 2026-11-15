#!/bin/sh
# Prints who holds a TCP port on this machine (#113, PR #188). start_local_stack.sh runs it when
# `supabase start` fails because a container could not bind a host port. On 2026-11-11 the
# sync-device job's database could not bind 54422 on a fresh runner (run 42956155985), nothing in
# the job had used the port, and the runner was gone before anyone could ask what held it.
#
# The likely cause, unproven: Linux gives an outgoing connection a local port from its ephemeral
# range (32768-60999 by default), which takes in every port the stack binds (54420-54429), so an
# outgoing connection such as an image pull can hold one when the database binds it. This prints
# what tells that apart from a listener: the range, and every socket whose local end is the port.
# An outgoing connection shows as ESTAB or TIME-WAIT with a remote peer; a listener as LISTEN, with
# its process where sudo lets ss name one.
#
# It runs after the CLI has stopped its own containers, so a holder that was one of the stack's own
# containers is gone by then. Linux only: elsewhere it says what it could not read. It never fails,
# so the start's own exit status is what the job reports.

port="$1"
echo "port $port: ephemeral range $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo unknown)"
if command -v ss >/dev/null 2>&1; then
  sudo -n ss -tanp "( sport = :$port )" 2>/dev/null || ss -tan "( sport = :$port )"
elif [ -r /proc/net/tcp ]; then
  hex=$(printf '%04X' "$port")
  # The state column is hex, decoded in proc(5). It is not spelled out here: the test reads the
  # holder's state from this output, and a legend would match whatever the holder was.
  echo "port $port: no ss here, so /proc/net/tcp (local address, remote address, state in hex):"
  awk -v h=":$hex" 'FNR == 1 && NR == 1 || $2 ~ h "$"' /proc/net/tcp /proc/net/tcp6 2>/dev/null
else
  echo "port $port: neither ss nor /proc/net/tcp is readable here, so who holds it is not known"
fi
exit 0
