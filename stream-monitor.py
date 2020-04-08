#!/usr/bin/env python
"""
Internet Bandwidth Report

Reference:  https://electronicshobbyists.com/raspberry-pi-pwm-tutorial-control-brightness-of-led-and-servo-motor/
            https://gist.github.com/racerxdl/d4b4670d189ad579ae1a
            
"""
import os
import RPi.GPIO as GPIO

def GetNetworkStats():
    """Obtain networking statistics from /proc/net/dev.
       Reference code by Lucas Teske, https://gist.github.com/racerxdl/d4b4670d189ad579ae1a
    """
    ifaces = {}
    with open(os.path.join(os.path.sep,'proc','net','dev'),'r') as f:
        data = f.read().split('\n')[2:]
    for i in data:
        if len(i.strip()) > 0:
            x = i.split()
            # Interface |                        Receive                          |                         Transmit
            #   iface   | bytes packets errs drop fifo frame compressed multicast | bytes packets errs drop fifo frame compressed multicast
            k = {
                "interface" :   x[0][:len( x[0])-1],   
                "tx"        :   {
                    "bytes"         :   int(x[1]),
                    "packets"       :   int(x[2]),
                    "errs"          :   int(x[3]),
                    "drop"          :   int(x[4]),
                    "fifo"          :   int(x[5]),
                    "frame"         :   int(x[6]),
                    "compressed"    :   int(x[7]),
                    "multicast"     :   int(x[8])
                },
                "rx"        :   {
                    "bytes"         :   int(x[9]),
                    "packets"       :   int(x[10]),
                    "errs"          :   int(x[11]),
                    "drop"          :   int(x[12]),
                    "fifo"          :   int(x[13]),
                    "frame"         :   int(x[14]),
                    "compressed"    :   int(x[15]),
                    "multicast"     :   int(x[16])
                }
            }
            ifaces[k['interface']] = k
    return ifaces

# ---------------------------------------------------------------------------
# For command-line testing
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys, time

    dev = sys.argv[1] if len(sys.argv)>1 else os.environ.get('MONITOR_DEV', 'wlan0')
    pin = sys.argv[2] if len(sys.argv)>2 else os.environ.get('MONITOR_PIN', '21')
    bitrate = sys.argv[3] if len(sys.argv)>3 else os.environ.get('H264_BITRATE', '1800')
    pwm_hz = sys.argv[4] if len(sys.argv)>4 else os.environ.get('MONITOR_PWM_HZ', '100')
    update_sec = sys.argv[5] if len(sys.argv)>5 else os.environ.get('MONITOR_UPDATE_SEC', '1.0')

    pin = int(pin, 0)
    bytes_per_sec = int(bitrate, 0) * 8.0
    pwm_hz = int(pwm_hz, 0)
    update_sec = float(update_sec)

    GPIO.setmode(GPIO.BCM)
    GPIO.setup(pin, GPIO.OUT)
    pwm = GPIO.PWM(pin, pwm_frequency)
    pwm.start(0)                # 0% duty cycle
    
    last = GetNetworkStats()    # initial statistics
    factor = 100.0 * update_sec / bytes_per_sec
    try:
        while True:
            time.sleep(update_sec)
            stats = GetNetworkStats()
            bytes_n = last[dev]['tx']['bytes']
            bytes_n_plus_1 = stats[dev]['tx']['bytes']
            delta = bytes_n_plus_1 - bytes_n
            ratio = int( delta * factor, 0)

            sys.stdout.write('{}: {}/{} bytes, ratio={}\n', dev, delta, factor / 100, ratio)

            pwm.ChangeDutyCycle(ratio)
    except KeyboardInterrupt:
        pass

    pwm.stop()
    #GPIO.cleanup()              # CHECK: this doesn't affect *other* GPIOs does it?
