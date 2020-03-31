#!/usr/bin/env python
"""
Internet Connectivity Test

This is a function to determine whether internet connectivity is functional.
The basic principle is to open a socket to a well-known port via TCP/IP.
If the internet is available, then the socket will connect, otherwise it will not.

It is apparently faster than interpreting the response to an ICMP.  Derogatory
comments on the use of the method focus on "why not just do the transaction you
want to do"...  The use case is when you need a generic test for internet apart
from any application logic.  ICMP and/or DNS or other services can be used, but
are arguably more resource intensive for both sides.

The default method here is to use a port (such as 443) that is serviced by your
server already (and likely load balanced and redundant).  Only half of the transaction
is performed, as '7h3rAm' says and is demonstrably faster.


    > python internet.py
    online({'servers': ['8.8.8.8', '192.74.137.5', '96.127.43.43']}): True in 0.159 sec

    > python internet.py ping

    Pinging 8.8.8.8 with 32 bytes of data:
    Reply from 8.8.8.8: bytes=32 time=25ms TTL=49

    Ping statistics for 8.8.8.8:
        Packets: Sent = 1, Received = 1, Lost = 0 (0% loss),
    Approximate round trip times in milli-seconds:
        Minimum = 25ms, Maximum = 25ms, Average = 25ms
    ping({'host': '8.8.8.8'}): True in 0.115 sec

    > python internet.py socket
    socket({'host': '8.8.8.8'}): True in 0.027 sec

Reference:  https://stackoverflow.com/questions/3764291/checking-network-connection
            https://stackoverflow.com/questions/10415028/how-can-i-recover-the-return-value-of-a-function-passed-to-multiprocessing-proce
"""
import socket

_DEFAULT_IP_LIST = [ '8.8.8.8', '192.74.137.5', '96.127.43.43' ]

def internet(host='8.8.8.8', port=443, timeout=3):
    """
    Host: 8.8.8.8 (google-public-dns-a.google.com)
    OpenPort: 443/tcp
    Service: domain (DNS/TCP)
    """
    try:
        socket.setdefaulttimeout(timeout)
        socket.socket(socket.AF_INET, socket.SOCK_STREAM).connect((host, port))
        return True
    except socket.error as ex:
        print(ex)
        return False

def online(servers=_DEFAULT_IP_LIST):
    response = [ internet(h) for h in servers ]
    if any(response):
        return True
    return False

def ping(host):
    """
    Returns True if host (str) responds to a ping request.
    Remember that some hosts may not respond to a ping request even if the host name is valid.
    """
    # https://stackoverflow.com/questions/2953462/pinging-servers-in-python
    from platform import system as system_name # Returns the system/OS name
    from os import system as system_call       # Execute a shell command

    # Ping parameters as function of OS
    parameters = "-n 1" if system_name().lower()=="windows" else "-c 1"

    # Pinging
    return system_call("ping " + parameters + " " + host) == 0

# ---------------------------------------------------------------------------
# For command-line testing
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys, time

    method = ( online, 'online' )
    if len(sys.argv)>1:
        if sys.argv[1].startswith('sock'): method = ( internet, 'socket' )
        else: method = ( ping, 'ping' )

        d = { 'host':sys.argv[2] if len(sys.argv)>2 else '8.8.8.8' }
        if method[1].startswith('socket'):
            if len(sys.argv)>3: d['port'] = int(sys.argv[3], 0)
            if len(sys.argv)>4: d['timeout'] = float(sys.argv[4])

    else:
        d = { 'servers':_DEFAULT_IP_LIST }

    then = time.time()
    up = method[0](**d)
    sys.stderr.write('{}({}): {} in {:.3f} sec\n'.format(method[1], d, up, time.time()-then))
    sys.exit(0 if up else 1)
