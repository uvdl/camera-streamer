#!/bin/bash
# usage:
#   caps.sh [PATH [DEV]]
#
# where:
#   PATH: path to folder to collect all data files produced
#   DEV: path to v4l2 device (or enumerate all devices)

# allow for command-line overrides
declare -A config
config[path]=${1:-/tmp/caps.$$} ; shift
config[devs]=$*
if [ -z "${config[devs]}" ] ; then config[devs]=$(ls /dev/video* 2>/dev/null) ; fi

mkdir -p ${config[path]}
echo "*** V4L2 ***"
for d in ${config[devs]} ; do
	echo "*** $d ***"
	fpart=${config[path]}/$(basename $d)
	if v4l2-ctl -d $d --list-formats > ${fpart}.fmt ; then
		v4l2-ctl -d $d --list-ctrls > ${fpart}.ctrls
		v4l2-ctl -d $d --all > ${fpart}.all
		( gst-launch-1.0 --gst-debug=v4l2src:5 v4l2src device=$d num-buffers=0 ! fakesink 2>&1 | sed -une '/caps of src/ s/[:;] /\n/gp' ) > ${fpart}.txt
	fi
done
echo "*** ALSASRC ***"
# https://stackoverflow.com/a/1521470
if aplay -l > ${config[path]}/audio.txt ; then
	echo "**** Capabilities ****" >> ${config[path]}/audio.txt
	aplay -l | grep 'card.*device' | while read p || [[ -n $p ]] ; do
		c=$(echo $p | cut -f1 -d, | cut -f1 -d: | cut -f2 -d' ')
		d=$(echo $p | cut -f2 -d, | cut -f1 -d: | cut -f3 -d' ')
		echo -n "*** hw:$c,$d "
		x=$(gst-launch-1.0 -v alsasrc device="hw:${c},${d}" num-buffers=0 ! fakesink 2>&1 | sed -une '/src: caps/ s/[:;] /\n/gp')
		if [ -z "$x" ] ; then echo "NO" ; else echo "    hw:${c},${d} $x" >> ${config[path]}/audio.txt ; echo "OK, ${config[path]}/audio.txt" ; fi
	done
fi
echo "*** USB ***"
lsusb > ${config[path]}/usb.lst
lsusb -v 2>/dev/null > ${config[path]}/usb.txt
gst-inspect-1.0 | sort > ${config[path]}/gst.lst

echo "*** ${config[path]}"
ls -al ${config[path]}
