#!/usr/bin/env python
"""
Internet Bandwidth Report

Reference:  https://electronicshobbyists.com/raspberry-pi-pwm-tutorial-control-brightness-of-led-and-servo-motor/
            https://gist.github.com/racerxdl/d4b4670d189ad579ae1a
            
"""
import os

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

try:
    import RPi.GPIO as GPIO
except ImportError:
    # for duck-typing on non-RPi systems
    class GPIO(object):
        BCM = 11
        OUT = 0
        IN = 1
        def __init__(self):
            pass
        @staticmethod
        def cleanup():
            pass
        @staticmethod
        def setmode(_x):
            pass
        @staticmethod
        def setup(_pin, _dir):
            pass
        class PWM(object):
            def __init__(self, _pin, _hz):
                pass
            def start(self, _duty):
                pass
            def stop(self):
                pass
            def ChangeDutyCycle(self, _duty):
                pass

if __name__ == "__main__":
    import sys, time

    dev = sys.argv[1] if len(sys.argv)>1 else os.environ.get('MONITOR_DEV', os.environ.get('UDP_IFACE', 'wlan0'))
    pin = sys.argv[2] if len(sys.argv)>2 else os.environ.get('MONITOR_PIN', '21')
    kbps = sys.argv[3] if len(sys.argv)>3 else os.environ.get('MONITOR_KBPS', os.environ.get('VIDEO_BITRATE', '1800'))
    pwm_hz = sys.argv[4] if len(sys.argv)>4 else os.environ.get('MONITOR_PWM_HZ', '100')
    update_sec = sys.argv[5] if len(sys.argv)>5 else os.environ.get('MONITOR_UPDATE_SEC', '1.0')

    pin = int(pin, 0)
    bytes_per_sec = int(kbps, 0) * 8.0
    pwm_hz = int(pwm_hz, 0)
    update_sec = float(update_sec)

    sys.stderr.write('pin={}, bytes/sec={}, pwm={}, update={}\n'.format(pin, bytes_per_sec, pwm_hz, update_sec))

    GPIO.setmode(GPIO.BCM)
    GPIO.setup(pin, GPIO.OUT)
    pwm = GPIO.PWM(pin, pwm_hz)
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
            ratio = delta * factor

            sys.stdout.write('{}: {}/{:.0f} bytes, ratio={:0.1f}\n'.format(dev, delta, 100.0/factor, ratio))
            if ratio < 0: ratio = 0
            elif ratio > 100: ratio = 100

            pwm.ChangeDutyCycle(ratio)
            last = stats

    except KeyError as e:
        sys.stderr.write('{}: No such interface\n'.format(str(e)))
    except KeyboardInterrupt:
        pass
    finally:
        pwm.stop()
        GPIO.cleanup()
