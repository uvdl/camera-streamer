#!/bin/bash
# usage:
#   provision.sh filename [--dry-run]
#
# Interactively create/update a systemd service configuration file

SUDO=$(test ${EUID} -ne 0 && which sudo)
SYSCFG=/etc/systemd
UDEV_RULESD=/etc/udev/rules.d

CONF=$1
shift
DEFAULTS=false
DRY_RUN=false
while (($#)) ; do
	if [ "$1" == "--dry-run" ] && ! $DRY_RUN ; then DRY_RUN=true ; set -x ;
	elif [ "$1" == "--defaults" ] ; then DEFAULTS=true ;
	fi
	shift
done

function address_of {
	local result=$(ip addr show $1 | grep inet | grep -v inet6 | head -1 | sed -e 's/^[[:space:]]*//' | cut -f2 -d' ' | cut -f1 -d/)
	echo $result
}

function value_of {
	local result=$($SUDO grep $1 $CONF 2>/dev/null | cut -f2 -d=)
	if [ -z "$result" ] ; then result=$2 ; fi
	echo $result
}

# pull default provisioning items from the network.conf (generate it first)
function value_from_network {
	local result=$($SUDO grep $1 $(dirname $CONF)/network.conf 2>/dev/null | cut -f2 -d=)
	if [ -z "$result" ] ; then result=$2 ; fi
	echo $result
}

function interactive {
	local result
	read -p "${2}? ($1) " result
	if [ -z "$result" ] ; then result=$1 ; elif [ "$result" == "*" ] ; then result="" ; fi
	echo $result
}

function contains {
	local result=no
	#if [[ " $2 " =~ " $1 " ]] ; then result=yes ; fi
	if [[ $2 == *"$1"* ]] ; then result=yes ; fi
	echo $result
}

# configuration values used in this script
declare -A config
config[iface]=$(value_from_network IFACE wlan0)

case "$(basename $CONF)" in

	camera-switcher.conf)
		config[cam1]=$(value_of CAM1 "")
		config[cam2]=$(value_of CAM2 "")
		config[cam3]=$(value_of CAM3 "")
		if ! $DEFAULTS ; then
			echo ""
			for d in /dev/video[0-9]* ; do
				echo "*** $d ***"
				if udevadm info -a -n $d | grep ATTRS | grep -E 'manufacturer|product|devpath' | head -3 ; then
					v4l2-ctl -d $d --list-formats
					echo ""
				fi
			done
			config[cam1]=$(interactive "${config[cam1]}" "Select device number (/dev/video*) for camera 1")
			config[cam2]=$(interactive "${config[cam2]}" "Select device number (/dev/video*) for camera 2 (x disables)")
			config[cam3]=$(interactive "${config[cam3]}" "Select device number (/dev/video*) for camera 3 (x disables)")
		fi
		# generate udev rules for selected cameras
		touch /tmp/$$.rule
		for n in 1 2 3 ; do
			# https://wiki.archlinux.org/index.php/Udev#Video_device
			if [ "${config[cam${n}]}" == "x" ] ; then
				echo "*** cam${n} skipped ***"
			elif [ ! -z "${config[cam${n}]}" ] ; then
				ok=true
				udevadm info -a -n /dev/video${config[cam${n}]} | grep ATTR > /tmp/camera${n}.$$
				for kw in devpath idProduct idVendor index ; do
					config[$kw]=$(grep $kw /tmp/camera${n}.$$ | head -1 | cut -f2 -d\")
					if [ -z "${config[$kw]}" ] ; then ok=false ; fi
				done
				if $ok ; then
					echo "SUBSYSTEM==\"video4linux\", ATTRS{idVendor}==\"${config[idVendor]}\", ATTRS{idProduct}==\"${config[idProduct]}\", ATTRS{devpath}==\"${config[devpath]}\", ATTR{index}==\"${config[index]}\", SYMLINK+=\"cam${n}\"" >> /tmp/$$.rule
				else
					echo "*** /dev/video${config[cam${n}]} not configured for cam${n} ***"
				fi
			fi
		done
		if $DRY_RUN ; then
			echo ${UDEV_RULESD}/83-webcam.rules && cat /tmp/$$.rule && echo ""
		else
			set -x
			$SUDO install -Dm644 /tmp/$$.rule ${UDEV_RULESD}/83-webcam.rules
			$SUDO udevadm control --reload-rules && $SUDO udevadm trigger
			set +x
		fi
		echo "[Service]" > /tmp/$$.env && \
		echo "CAM1=${config[cam1]}" >> /tmp/$$.env && \
		echo "CAM2=${config[cam2]}" >> /tmp/$$.env && \
		echo "CAM3=${config[cam3]}" >> /tmp/$$.env && \
		echo "CONF=$(dirname $CONF)/video-stream.conf" >> /tmp/$$.env
		;;

	camera-switcher.sh)
		# https://unix.stackexchange.com/questions/79068/how-to-export-variables-that-are-set-all-at-once
		# set -a && source /etc/systemd/video-stream.conf && set +a
		x=$(tail -n +2 /etc/systemd/video-stream.conf) && set -a && eval $x && set +a
		# now we have the environment settings for video
		p1=$(PLATFORM=${PLATFORM} VIDEO_DEVICE=/dev/cam1 FLAGS=debug,smpte,${FLAGS} ./video-stream.sh 2>/dev/null)
		p2=$(PLATFORM=${PLATFORM} VIDEO_DEVICE=/dev/cam2 FLAGS=debug,smpte,${FLAGS} ./video-stream.sh 2>/dev/null)
		p3=$(PLATFORM=${PLATFORM} VIDEO_DEVICE=/dev/cam3 FLAGS=debug,smpte,${FLAGS} ./video-stream.sh 2>/dev/null)
		if [ -z "$p1" ] ; then echo "*** Did not produce cam1 pipeline - STOP" ; exit 1 ; fi
		if [ -z "$p2" ] ; then echo "*** Did not produce cam2 pipeline - STOP" ; exit 1 ; fi
		if [ -z "$p3" ] ; then echo "*** Did not produce cam3 pipeline - STOP" ; exit 1 ; fi
		# now we have the 3 pipelines that should be executed
		echo "#!/bin/bash" > /tmp/$$.env && \
		echo "# ensure previous pipelines are cancelled and cleared" >> /tmp/$$.env && \
		echo "gstd -f /var/run -l /dev/null -d /dev/null -k" >> /tmp/$$.env && \
		echo "gstd -f /var/run -l /var/run/camera-switcher/gstd.log -d /var/run/camera-switcher/gst.log" >> /tmp/$$.env && \
		echo "gst-client pipeline_create cam1 $p1" >> /tmp/$$.env && \
		echo "gst-client pipeline_create cam2 $p2" >> /tmp/$$.env && \
		echo "gst-client pipeline_create cam3 $p3" >> /tmp/$$.env && \
		echo "# start cam1 by default" >> /tmp/$$.env && \
		echo "gst-client pipeline_play cam1" >> /tmp/$$.env && \
		echo "" >> /tmp/$$.env
		;;

	audio-streamer.conf)
		IFACE=$(value_of IFACE ${config[iface]})
		HOST=$(value_of HOST 224.1.$(echo $(address_of ${IFACE}) | cut -f3,4 -d.))
		_NAME=$(value_of NAME "") ; NAME=${_NAME//\"}
		PORT=$(value_of PORT 5601)
		if ! $DEFAULTS ; then
			arecord -l | grep 'card.*device'
			NAME=$(interactive "$NAME" "Audio device name")
			IFACE=$(interactive "$IFACE" "UDP Interface for audio")
			HOST=$(interactive "$HOST" "UDP IPv4 for audio")
			PORT=$(interactive "$PORT" "UDP PORT for audio")
		fi
		echo "[Service]" > /tmp/$$.env && \
		echo "IFACE=${IFACE}" >> /tmp/$$.env && \
		echo "HOST=${HOST}" >> /tmp/$$.env && \
		echo "NAME=\"${NAME//\"}\"" >> /tmp/$$.env && \
		echo "PORT=${PORT}" >> /tmp/$$.env
		;;

	audio-streamer.sh)
		# https://unix.stackexchange.com/questions/79068/how-to-export-variables-that-are-set-all-at-once
		x=$(tail -n +2 /etc/systemd/audio-streamer.conf) && set -a && eval $x && set +a
		# now we have the environment settings for audio
		if [ "${NAME}" == "x" ] ; then
			p1="audiotestsrc wave=white-noise freq=100 is-live=true \
				! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" \
				! voaacenc bitrate=128000 ! aacparse ! rtpmp4apay pt=96 \
				! udpsink name=output host=${HOST} PORT={PORT} multicast-iface=${IFACE} auto-multicast=true ttl=10"
		else
			p1=$(PLATFORM=${PLATFORM} IFACE=${IFACE} HOST=${HOST} NAME=\"${NAME}\" PORT=${PORT} DEBUG=true ./audio-stream.sh 2>/dev/null)
		fi
		if [ -z "$p1" ] ; then echo "*** Did not produce audio pipeline - STOP" ; exit 1 ; fi
		echo "#!/bin/bash" > /tmp/$$.env && \
		echo "gst-launch-1.0 $p1" >> /tmp/$$.env && \
		echo "" >> /tmp/$$.env
		;;

	video-stream.conf)
		# special case of provisioning the single camera streamer
		UDP_IFACE=$(value_of UDP_IFACE eth0)
		UDP_HOST=$(value_of UDP_HOST 224.1.$(echo $(address_of ${UDP_IFACE}) | cut -f3,4 -d.))
		UDP_PORT=$(value_of UDP_PORT 5600)
		WIDTH=$(value_of WIDTH 1280)
		HEIGHT=$(value_of HEIGHT 720)
		FPS=$(value_of FPS 30)
		VIDEO_BITRATE=$(value_of VIDEO_BITRATE 1800)
		FLAGS=$(value_of FLAGS "h264,xraw,scale,udp")
		URL=$(value_of URL udp)
		USERNAME=$(value_of USERNAME $USER)
		IDENT=$(value_of IDENT "")
		SKEY=$(value_of SKEY $(python3 serial_number.py))
		if ! $DEFAULTS ; then
			UDP_HOST=$(interactive "$UDP_HOST" "RJ45 Network IPv4 destination for video")
			WIDTH=$(interactive "$WIDTH" "Video stream width")
			HEIGHT=$(interactive "$HEIGHT" "Video stream height")
			FPS=$(interactive "$FPS" "Video stream frames/sec")
			VIDEO_BITRATE=$(interactive "$VIDEO_BITRATE" "Video stream bitrate in kbps/sec")
			FLAGS=$(interactive "$FLAGS" "Video stream flags")
			URL=$(interactive "$URL" "Video server URL")
			if [ "$(contains rtmp $URL)" == "yes" ] ; then
				if [ "$(contains mavnet.online $URL)" == "yes" ] ; then\
					# video.mavnet.online authenticates by username
					USERNAME=$(interactive "$USERNAME" "Username for video server")
					read -s -p "Password? " IDENT ; echo "" ;
				else
					# Facebook, YouTube, etc. authenticate via stream-key
					SKEY=$(interactive "$SKEY" "RTMP server stream key")
				fi
			fi
		fi
		echo "[Service]" > /tmp/$$.env && \
		echo "PLATFORM=${PLATFORM}" >> /tmp/$$.env && \
		echo "UDP_IFACE=${UDP_IFACE}" >> /tmp/$$.env && \
		echo "UDP_HOST=${UDP_HOST}" >> /tmp/$$.env && \
		echo "UDP_PORT=${UDP_PORT}" >> /tmp/$$.env && \
		echo "WIDTH=${WIDTH}" >> /tmp/$$.env && \
		echo "HEIGHT=${HEIGHT}" >> /tmp/$$.env && \
		echo "FPS=${FPS}" >> /tmp/$$.env && \
		echo "VIDEO_BITRATE=${VIDEO_BITRATE}" >> /tmp/$$.env && \
		echo "FLAGS=${FLAGS}" >> /tmp/$$.env && \
		echo "USERNAME=${USERNAME}" >> /tmp/$$.env && \
		echo "IDENT=${IDENT}" >> /tmp/$$.env && \
		echo "SKEY=${SKEY}" >> /tmp/$$.env && \
		echo "URL=${URL}" >> /tmp/$$.env
		;;

	*)
		# preserve contents or generate a viable empty configuration
		echo "[Service]" > /tmp/$$.env
		;;
esac

if $DRY_RUN ; then
	set +x
	echo $CONF && cat /tmp/$$.env && echo ""
elif [[ $(basename $CONF) == *.sh ]] ; then
	$SUDO install -Dm755 /tmp/$$.env $CONF
else
	$SUDO install -Dm644 /tmp/$$.env $CONF
fi
rm /tmp/$$.env
