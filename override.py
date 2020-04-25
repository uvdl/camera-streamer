import os, sys

def hosts(server, output, flags):
    """Ensure that (video.)server is listed in the hosts file."""
    video = server if server.startswith('video.') else 'video.'+server
    # handle special case of 'dev.mavnet.online' which still uses video.mavnet.online
    if server.startswith('dev.'):
        video = 'video.'+'.'.join(server.split('.')[1:])
    with open(output,'r') as f:
        txt = f.read()
        if all([svr in txt.split() for svr in [server, video]]):
            return  # nothing needs to be added
        for svr in [server, video]:
            if not svr in txt.split():
                ip = os.popen('host '+svr).read().strip().split('\n')[0].split(' ')[-1]
                if 'NXDOMAIN' in ip: continue
                txt = txt + '\n{}\t{}'.format(ip, svr)
        if 'dry-run' in flags:
            sys.stdout.write(txt+'\n')
            return
        with open(output,'w') as g:
            g.write(txt+'\n')
            sys.stderr.write('wrote {}\n'.format(g.name))

def interfaces(ipv4, output, flags):
    """Re-write /etc/network/interfaces."""
    txt = """
auto lo
iface lo inet loopback

"""
    if len(ipv4.strip().split('.'))==4:
        txt = txt + 'iface eth0 inet static\n'
        lan = ipv4
        txt = txt + '    address {}\n'.format(lan)
        txt = txt + '    netmask {}\n'.format('255.255.0.0')
        txt = txt + '    network {}.0.0\n'.format('.'.join([x for x in lan.split('.')[0:2]]))

    if 'dry-run' in flags:
        sys.stdout.write(txt)
        return
    with open(output,'w') as f:
        f.write(txt+'\n')
        sys.stderr.write('wrote {}\n'.format(f.name))

if __name__ == "__main__":
    output = sys.argv[2]
    flags = sys.argv[3].split(',') if len(sys.argv)>3 else ''
    if output.endswith('hosts'):
        hosts(sys.argv[1], output, flags)
    elif output.endswith('interfaces'):
        interfaces(sys.argv[1], output, flags)
