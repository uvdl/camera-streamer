#!/bin/bash
# usage:
#   video-stream.sh [WIDTH [HEIGHT [FPS [KBPS [URL [SKEY [FLAGS]]]]]]]
#
# where:
#   WIDTH, HEIGHT, FPS: are integers describing the desired output stream
#   KBPS: is an integer describing the desired bitrate in kilobits-per-sec
#   URL: overrides the stream URL in the config file
#   SKEY: overrides the stream key in the config file
#   FLAGS: overrides a list of flags to enable
#     audio - enable audio source multiplexing
#     debug - perform a dry-run and only report the pipeline that would be executed
#     encd - prefer H.264/H.265 source from camera
#     h264 - make output stream be H.264
#     h265 - make output stream be H.265
#     mjpg - fallback to Motion JPEG
#     preview - render outgoing stream on local framebuffer
#     progressreport - inject a progress report on the preview stream
#     rtmp - enable rtmp output (to the WAN)
#     scale - allow (up) scaling to reduce data rate from camera to encoder
#     single - allow either rtmp or udp not both
#     snow - use random data for video when no suitable camera is found
#     speedtest - test and document upstream WAN bandwidth before starting stream (depends on wan enable)
#     udp - enable UDP output to LAN
#     wan - enable operations on wide-area-networks (internet)
#     xraw - fallback to RAW video (NB: may be bandwidth limited if using USB)
#
# TODO: https://github.com/Freescale/gstreamer-imx/issues/206
if [ -z "${LOGDIR}" ] ; then
	## NB: RUNTIME_DIRECTORY does not seem to be populated as the systemd docs say...
	##if [ -z "$RUNTIME_DIRECTORY" ] ; then LOGDIR=/tmp ; else LOGDIR=$RUNTIME_DIRECTORY ; fi
	if [ -d /var/run/video-stream ] ; then LOGDIR=/var/run/video-stream ; else LOGDIR=/tmp/video-stream.$$ ; fi
else
	if ! mkdir -p ${LOGDIR} ; then LOGDIR=/tmp/video-stream.$$ ; fi
fi
log=${LOGDIR}/video.log
# configuration items (defaults)
declare -A config
config[width]=${WIDTH} ; if [ -z "${config[width]}" ] ; then config[width]=1280 ; fi
config[height]=${HEIGHT} ; if [ -z "${config[height]}" ] ; then config[height]=720 ; fi
config[fps]=${FPS} ; if [ -z "${config[fps]}" ] ; then config[fps]=30 ; fi
config[kbps]=${VIDEO_BITRATE} ; if [ -z "${config[kbps]}" ] ; then config[kbps]=1800 ; fi
config[flags]="${FLAGS}"
config[audio]="${AUDIO}"                    # device identifier selected from $(aplay -l | grep 'card.*device')
config[audio_latency]=${AUDIO_LATENCY_MS}   # override computed latency
config[video_latency]=${VIDEO_LATENCY_MS}   # override computed latency
config[audio_encoders]="${AUDIO_ENCODERS}"  # list of audio encoders to use
config[video_encoders]="${VIDEO_ENCODERS}"  # list of video encoders to use
config[video_scalers]="${VIDEO_SCALERS}"    # list of video scalers to use
config[video_device]=${VIDEO_DEVICE}        # video device path to use (empty to autoselect)
config[video_profile]=${VIDEO_PROFILE}      # high, main, baseline or empty
config[video_rate]=${VIDEO_RATE}            # constant, variable or empty
# NB: the exact ratio of the max-size-time parameter between the flvmux latency
#     and the audio buffer is still a subject of investigation.  Empirical
#     results show that 5:1 can work for minimum-latency applications, but 10:10
#     is more robust for broadcast applications.
if [ -z "${config[video_latency]}" ] ; then
	# user desires minimum latency
	config[audmux_ratio]=5
	config[flvmux_ratio]=1
	config[video_latency]=0
else
	# user desires broadcast robustness
	config[flvmux_ratio]=10
	config[audmux_ratio]=10
fi
# allow for command-line override
config[width]=${1:-${config[width]}}
config[height]=${2:-${config[height]}}
config[fps]=${3:-${config[fps]}}/1
config[kbps]=${4:-${config[kbps]}}      # NB: only loosely connected to what you actually get...
config[url]=${5:-${URL}}
config[streamkey]=${6:-${SKEY}}
config[flags]="${7:-${config[flags]}}"
# udp configuration/defaults
declare -A udp
udp[host]=${UDP_HOST} ; if [ -z "${udp[host]}" ] ; then udp[host]=224.1.1.1 ; fi
udp[iface]=${UDP_IFACE} ; if [ -z "${udp[iface]}" ] ; then udp[iface]=eth0 ; fi
udp[port]=${UDP_PORT} ; if [ -z "${udp[port]}" ] ; then udp[port]=5600 ; fi
udp[ttl]=${UDP_TTL} ; if [ -z "${udp[ttl]}" ] ; then udp[ttl]=10 ; fi
# Need to add multicast-iface if multicasting...
if [ ${udp[host]/.*} -ge 224 -a ${udp[host]/.*} -le 239 ] ; then
	udp[props]="host=${udp[host]} port=${udp[port]} multicast-iface=${udp[iface]} auto-multicast=true ttl=${udp[ttl]}"
else
	udp[props]="host=${udp[host]} port=${udp[port]}"
fi

# defaults and flags
_FLG="audio,debug,encpipe,encd,h264,h265,mjpg,preview,progressreport,rtmp,scale,single,snkpipe,snow,speedtest,srcpipe,udp,wan,xraw"
declare -A enable
for k in $(IFS=',';echo $_FLG) ; do
	if [ -z "$(echo ${config[flags]} | grep -E $k)" ] ; then enable[$k]=false ; else enable[$k]=true ; fi
done
# legacy debug behavior...
if ${enable[debug]} ; then
	if ! ${enable[encpipe]} && ! ${enable[srcpipe]} && ! ${enable[snkpipe]} ; then
		enable[encpipe]=true
		enable[srcpipe]=true
		enable[snkpipe]=true
	fi
fi

# gstreamer pipeline segments
declare -A gst
gst[version]=$(gst-launch-1.0 --version | head -1)
gst[videoscale]="videoscale"
gst[videoscale_formats]="I420|YUY2|UYVY|YVYU|NV12|GRAY8|BGRx|RGBA"

# Select which encoders are possible
if [ -z "${config[video_scalers]}" ] ; then
	if [ "${PLATFORM}" == "IMX6" ] ; then
		config[video_scalers]="imxipuvideotransform"
	elif [ "${PLATFORM}" == "NVID" ] ; then
		config[video_scalers]="nvvidconv"
	fi
fi
if [ -z "${config[video_encoders]}" ] ; then
	if ${enable[h265]} ; then
		config[video_encoders]="imxvpuenc_h265,omxh265enc,x265enc"
	elif ${enable[h264]} ; then
		config[video_encoders]="imxvpuenc_h264,omxh264enc,x264enc"
	else
		# This is an invalid configuration that will get trapped in encoder selection below.
		config[video_encoders]=""
	fi
fi
if [ -z "${config[audio_encoders]}" ] ; then
	#config[audio_encoders]="avenc_aac,voaacenc"
	config[audio_encoders]="voaacenc"
fi

# Define Encoder Pipelines (all types, the one used is selected based on availablity)
declare -A encoder
declare -A encoder_formats
declare -A scaler
declare -A scaler_formats

# i.MX6
encoder[imxvpuenc_h264]="imxvpuenc_h264 bitrate=${config[kbps]} idr-interval=$((${config[fps]} * 2))"
encoder_formats[imxvpuenc_h264]='I420|NV12|GRAY8'
# RPi, NVidia handled below
# Software encoders (most every system)
encoder[x264enc]="x264enc bitrate=${config[kbps]} speed-preset=veryfast key-int-max=$((${config[fps]} * 2))"
encoder_formats[x264enc]='I420|YV12|Y42B|Y444|NV12'
# Audio encoders
encoder[avenc_aac]="avenc_aac threads=auto bitrate=128000"
encoder_formats[avenc_aac]='F32LE'
encoder[voaacenc]="voaacenc bitrate=128000"
encoder_formats[voaacenc]='S16LE'

# adjustments
if [ -z "${config[video_latency]}" -o ${config[video_latency]} -lt 1 ] ; then
	encoder[x264enc]="${encoder[x264enc]} tune=zerolatency sliced-threads=true"
fi
# RPi variations are *so* different from Ubuntu/NVidia
if [ "${PLATFORM}" == "RPIX" ] ; then
	# NB: https://www.phoronix.com/forums/forum/software/desktop-linux/864973-libav-adds-h-264-mpeg4-encoders-using-openmax-il?p=865870#post865870
	encoder[avenc_h264_omx]="avenc_h264_omx bitrate=$((${config[kbps]} * 1000)) threads=auto keyint-min=$((${config[fps]} * 2))"
	encoder_formats[avenc_h264_omx]='I420'
	if [ ! -z "${config[video_profile]}" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} profile=${config[video_profile]}"
	fi
	if [ "${config[video_rate]}" == "constant" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} pass=cbr"
	elif [ "${config[video_rate]}" == "variable" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} pass=vbr"
	fi
	# https://www.raspberrypi.org/forums/viewtopic.php?t=240170
	encoder[v4l2h264enc]="v4l2h264enc"
	encoder_formats[v4l2h264enc]='I420|YV12|NV12|RGB16|RGB|BGR|BGRA|YUY2|YVYU|UYVY'
	extra="encode,video_bitrate=$((${config[kbps]} * 1000)),h264_i_frame_period=$((${config[fps]} * 2))"
	if [ ! -z "${config[video_profile]}" ] ; then
		extra="${extra},h264_profile=${config[video_profile]}"
	fi
	if [ "${config[video_rate]}" == "constant" ] ; then
		extra="${extra},video_bitrate_mode=1"
	elif [ "${config[video_rate]}" == "variable" ] ; then
		extra="${extra},video_bitrate_mode=0"
	fi
	encoder[v4l2h264enc]="${encoder[v4l2h264enc]} extra-controls=\"${extra}\""
# NVidia variations are different from Ubuntu
elif [ "${PLATFORM}" == "NVID" ] ; then
	encoder[omxh265enc]="omxh265enc bitrate=$((${config[kbps]} * 1000)) iframeinterval=$((${config[fps]} * 2))"
	encoder_formats[omxh265enc]='I420|NV12'
	encoder[omxh264enc]="omxh264enc bitrate=$((${config[kbps]} * 1000)) iframeinterval=$((${config[fps]} * 2))"
	encoder_formats[omxh264enc]='I420|NV12'
	if [ "${config[video_rate]}" == "constant" ] ; then
		encoder[omxh264enc]="${encoder[omxh264enc]} control-rate=constant"
	elif [ "${config[video_rate]}" == "variable" ] ; then
		encoder[omxh264enc]="${encoder[omxh264enc]} control-rate=variable-skip-frames"
	fi
	scaler[nvvidconv]="nvvidconv output-buffers=1"
	scaler_formats[nvvidconv]='I420|YUY2|UYVY|YVYU|NV12|GRAY8|BGRx|RGBA'
fi

# logging to file and stdout (which is journaled under systemd)
# https://stackoverflow.com/questions/2990414/echo-that-outputs-to-stderr
function LOG {
	mkdir -p $(dirname $log)
	echo "$(date --iso-8601='seconds') $*" >> $log
	>&2 echo "$*"
}

# various queue configurations
# common buffer-limited queue (argument defines number of buffers, arg2 for leaky)
function bufferqueue {
	local result="queue max-size-buffers=$1 max-size-bytes=0 max-size-time=0 min-threshold-buffers=1 $2"
	echo $result
}
# common time-limited queue (arguments defines number of milliseconds of queueing, arg2 for leaky)
function timequeue {
	local result="queue max-size-buffers=0 max-size-bytes=0 max-size-time=$(($1 * 1000000)) min-threshold-buffers=1 $2"
	echo $result
}

if ${enable[debug]} ; then
	for k in ${!config[@]} ; do
		>&2 echo "config[$k]=${config[$k]}"
	done
	for k in ${!enable[@]} ; do
		>&2 echo "enable[$k]=${enable[$k]}"
	done
	for k in ${!udp[@]} ; do
		>&2 echo "udp[$k]=${udp[$k]}"
	done
	dlog=/tmp/debug.$$ ; echo "$(date --iso-8601='seconds')" > $dlog
	>&2 echo "Diagnostic on $dlog"
else
	dlog=/dev/null
fi

# compute queue max-size-time parameter to avoid gstreamer
# "Impossible to configure latency" warnings/errors.  We calculate the amount
# of time for two frames at the desired frame rate (in nanoseconds).  Min 1ms.
# NB: if a framerate conversion is needed, one frame at the source and one frame at the output framerate will be needed.
fps=$(( ${config[fps]} ))
qmst=$(( ${config[video_latency]} ))
if [ $qmst -lt 1 ] ; then
	# user desires minimum latency
	if [ $fps -le 0 ] ; then qmst=1 ; else qmst=$(( (2000/$fps + 1) )) ; fi
fi
LOG DEBUG qmst=$qmst
# when audio is enabled, there is a minimum amount of latency that has to be taken
# into effect.  This causes the audmux and flvmux ratios to be recalculated.
# failure to do this will result in RTMP streaming errors
if ${enable[audio]} && ${enable[rtmp]} && [ $qmst -le 1700 ] ; then
	LOG WARNING audio+video over RTMP requires 1.7 sec latency, $qmst ms may be too little
fi

# Common parts for gst spells
function flvmux {
	# BEWARE: flvmux is reported to not support h.265
	local result="$(timequeue $qmst leaky=upstream) ! mux.video flvmux streamable=true name=mux"
	if [ "${PLATFORM}" == "RPIX" ] ; then result="$result latency=$(($qmst * ${config[flvmux_ratio]} * 1000000))" ; fi
	echo $result
}
function rtpmux {
	local result="$(timequeue $qmst leaky=upstream)"
	if ${enable[h265]} ; then
		result="$result ! rtph265pay config-interval=10 pt=96"
	elif ${enable[h264]} ; then
		result="$result ! rtph264pay config-interval=10 pt=96"
	fi
	result="$result ! mux.sink_0 rtpmux name=mux"
	echo $result
}
function encoder_args {
	local result
	if ${enable[h265]} ; then
		result="\"video/x-h265,stream-format=(string)byte-stream,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	else
		result="\"video/x-h264,stream-format=(string)byte-stream,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	fi
	if [ ! -z "${config[video_profile]}" ] ; then result="$result,profile=(string)${config[video_profile]}" ; fi
	if ${enable[h265]} ; then
		result="$result ! h265parse"
	else
		result="$result ! h264parse"
	fi
	echo $result
}
function mjpgargs {
	local result="\"image/jpeg,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	echo $result
}
function xrawargs {
	local result
	if [ -z "$4" ] ; then
		# format agnostic
		result="\"video/x-raw,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	elif [ -z "$3" ] ; then
		# format+framerate agnostic
		result="\"video/x-raw,width=(int)$1,height=(int)$2\""
	elif [ -z "$2" -o -z "$1" ] ; then
		result="\"video/x-raw\""
	else
		result="\"video/x-raw,format=(string)$4,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	fi
	echo $result
}
function overlay {
	local pad=25
	local width=$1
	local height=$2
	local fps=$3
	local name=$4
	shift 4
	if [ $height -gt 480 ] ; then pad=35 ; fi
	if [ $height -gt 720 ] ; then pad=55 ; fi
	local result="timeoverlay halignment=left valignment=top ypad=$(($pad * 2 + 25))"
	echo $result
}

function parse {
	local input=$1
	local key=$2
	local default=$3
	local e result
	for e in $(IFS=',';echo $input) ; do
		k=$(echo $e | cut -f1 -d=)
		v=$(echo $e | cut -f2 -d= | cut -f2 -d\) | cut -f1 -d,)
		if [ "$k" == "$key" ] ; then result=${v} ; fi
	done
	if [ -z "$result" ] ; then
		result=$default
	elif [ "$result" == "{" ] ; then
		# result is a list; pick the default if it is given
		if [ ! -z "$default" ] && echo $input | grep -E $key | grep -E $default >> $dlog ; then
			result=$default
		else
			# BOSON hack: pick 30fps
			if [ "$key" == "framerate" ] ; then
				result="30/1"
			fi
		fi
	fi
	echo $result
}

# UDP to IP:PORT (separate video and audio ports)

# Sync with server
if ${enable[wan]} ; then
	response=false
	internet=/usr/local/bin/internet.py
	if [ ! -e $internet ] ; then internet=./internet.py ; fi
	if [ -z "${SERVER}" ] ; then _ARG="" && SERVER="internet" ; else _ARG="socket ${SERVER}" ; fi
	LOG SYNC with ${SERVER} using $internet
	while true ; do
		if x=$(python $internet ${_ARG}) ; then response=true ; break ; fi
		sleep 5
	done
	if ! $response ; then
		LOG NO response from ${SERVER}, pipeline may fail
		#gst[avsink]="$(flvmux) ! fakesink"
		#gst[avsink]="$(rtpmux) ! fakesink"
	fi
fi

# Determine which device we will use
LOG SCAN
# Determine which video encoder we will use
for e in $(IFS=',';echo ${config[video_encoders]}) ; do
	LOG TRY $e
	if gst-inspect-1.0 $e >> $log ; then
		LOG SELECT $e
		gst[encoder]=${encoder[$e]}
		gst[encoder_formats]=${encoder_formats[$e]}
		break
	fi
done
if [ -z "${gst[encoder]}" ] || [ -z "${gst[encoder_formats]}" ] ; then
	if ${enable[debug]} ; then
		for k in ${!encoder[@]} ; do
			>&2 echo "encoder[$k]=${encoder[$k]}"
		done
		for k in ${!gst[@]} ; do
			>&2 echo "gst[$k]=${gst[$k]}"
		done
	fi
	if ${enable[mjpg]} || ${enable[xraw]} ; then
		# camera is jpeg or raw
		if ! ${enable[h264]} || ! ${enable[h265]} ; then
			LOG {h264,h265} not in FLAGS - pipeline cannot be constructed
			exit 1
		fi
	elif ! ${enable[encd]} ; then
		LOG Invalid FLAGS - pipeline cannot be constructed
		exit 1
	fi
fi

# Determine which video scaler we will use
if ${enable[scale]} ; then
	for e in $(IFS=',';echo ${config[video_scalers]}) ; do
		LOG TRY $e
		if [ ! -z "${scaler[$e]}" ] && gst-inspect-1.0 $e >> $log ; then
			LOG SELECT $e
			gst[videoscale]="${scaler[$e]}"
			gst[videoscale_formats]="${scaler_formats[$e]}"
			break
		fi
	done
	if [ "${gst[videoscale]}" == "videoscale" ] ; then
		LOG HW video scalers not available - using videoscale
	fi
fi

# video devices
# BEWARE: this is running in a separate shell, changes to the parent environment do not persist
function select_video_device {
	local d=$1 e f
	local format width height fps
	local result=""
	if v4l2-ctl -d $d --list-formats > /tmp/video.$$ ; then
		LOG DEBUG consider $d
		>&2 cat /tmp/video.$$ >> $log
		echo "*** $d ***" >> $dlog
		if grep H265 /tmp/video.$$ > /dev/null && ${enable[encd]} && ${enable[h265]} ; then
			result="h265 $d native ${config[width]} ${config[height]} ${config[fps]} stop"
			LOG $result
		elif grep H264 /tmp/video.$$ > /dev/null && ${enable[encd]} && ${enable[h264]} ; then
			result="h264 $d native ${config[width]} ${config[height]} ${config[fps]} stop"
			LOG $result
		elif grep MJPG /tmp/video.$$ > /dev/null && ${enable[mjpg]} ; then
			result="mjpg $d native ${config[width]} ${config[height]} ${config[fps]} stop"
			LOG $result
		elif ! ${enable[xraw]} ; then
			LOG DEBUG skip $d because raw format is not enabled
		elif [ -z "${gst[encoder_formats]}" ] ; then
			LOG DEBUG skip $d because no encoder format is given
		else
			( gst-launch-1.0 --gst-debug=v4l2src:5 v4l2src device=$d num-buffers=0 ! fakesink 2>&1 | sed -une '/caps of src/ s/[:;] /\n/gp' ) > /tmp/format.$$
			>&2 cat /tmp/format.$$ >> $log
			cat /tmp/format.$$ >> $dlog
			format=I420
			width=${config[width]}
			height=${config[height]}
			fps=${config[fps]}
			if ${enable[scale]} && [ ${height/.*} -gt 480 ] ; then width=$(( $width/2 )) ; height=$(( $height/2 )) ; fi
			echo "*** searching for $width x $height @ $fps" >> $dlog
			if grep -E ${gst[encoder_formats]} /tmp/format.$$ | grep -E $width | grep -E $height | grep -E "$fps" >> $dlog ; then
				# encoder format matches *and* frame size matches *and* fps matches
				result="xraw $d $format $width $height $fps"
				LOG NATIVE $result
			elif grep -E ${gst[videoscale_formats]} /tmp/format.$$ | grep -E $width | grep -E $height | grep -E "$fps" >> $dlog ; then
				# encode format can be converted and frame size matches *and* fps matches
				str=$(cat /tmp/format.$$ | grep -E ${gst[videoscale_formats]} | grep -E $width | grep -E $height | grep -E "$fps" | head -1)
				format=$(parse "$str" format)
				width=$width
				height=$height
				fps=$(parse "$str" framerate ${config[fps]})
				result="xraw $d $format $width $height $fps"
				LOG SCALE $result
				echo "*** scale result=$result" >> $dlog
			elif grep -E ${gst[videoscale_formats]} /tmp/format.$$ >> $dlog && ${enable[scale]} ; then
				# encode format can be converted and frame size matches - need to discover source parameters
				echo "*** trying ${gst[videoscale_formats]}" >> $dlog
				for f in $(IFS='|';echo ${gst[videoscale_formats]}) ; do
					LOG DEBUG try $f
					str=$(cat /tmp/format.$$ | grep -E $f | head -1)
					format=$(parse "$str" format)
					width=$(parse "$str" width)
					height=$(parse "$str" height)
					fps=$(parse "$str" framerate ${config[fps]})
					# reject any entry with missing parameters
					if [ -z "$format" -o -z "$width" -o -z "$height" -o -z "$fps" ] ; then continue ; fi
					# NB: prefer matching framerate->aspect ratio
					if [ "$fps" == "${config[fps]}" ] ; then
						LOG DEBUG select $format $width x $height because $fps fps matches
						result="xraw $d $format $width $height $fps"
						break
					elif [ $(( $width*100/$height )) -eq $(( ${config[width]}*100/${config[height]} )) ] ; then
						LOG DEBUG select $format $width x $height @ $fps because aspect ratio matches
						result="xraw $d $format $width $height $fps"
						break
					# NB: this implies that the last viable format wins...
					else
						echo "*** keeping $format $width x $height @ $fps" >> $dlog
						result="xraw $d $format $width $height $fps"
					fi
				done
				if [ -z "$result" ] ; then
					LOG DEBUG skip $d because not able to match format and frame size
				else
					LOG TRANSFORM $result
				fi
			else
				echo "*** encoder_formats=${gst[encoder_formats]}" >> $dlog
				echo "*** videoscale_formats=${gst[videoscale_formats]}" >> $dlog
				LOG DEBUG skip $d because no mode with image $width x $height exists or scaling disabled
			fi
		fi
	fi
	echo $result
}

declare -A dev
if [ -z "${config[video_device]}" ] ; then
	for dev in /dev/video* ; do
		kdtwhrs=$(select_video_device $dev)
		if [ -z "$kdtwhrs" ] ; then continue ; fi
		echo "*** kdtwhrs=$kdtwhrs" >> $dlog
		k="$(echo $kdtwhrs | cut -f1 -d' ')"
		d="$(echo $kdtwhrs | cut -f2 -d' ')"
		t="$(echo $kdtwhrs | cut -f3 -d' ')"
		w="$(echo $kdtwhrs | cut -f4 -d' ')"
		h="$(echo $kdtwhrs | cut -f5 -d' ')"
		r="$(echo $kdtwhrs | cut -f6 -d' ')"
		s="$(echo $kdtwhrs | cut -f7 -d' ')"
		dev[$k]=$d
		config[source_format]=$t
		config[source_width]=$w
		config[source_height]=$h
		config[source_fps]=$r
		if [ "$s" == "stop" ] ; then break ; fi
		LOG DEBUG continue to consider other devices
	done
else
	# script desires to use a particular device path
	kdtwhrs=$(select_video_device ${config[video_device]})
	if [ -z "$kdtwhrs" ] ; then
		LOG DEBUG ${config[video_device]} not suitable
		# exit 1
		kdtwhrs="test none false ${config[width]} ${config[height]}"
	fi
	echo "*** kdtwhrs=$kdtwhrs" >> $dlog
	k="$(echo $kdtwhrs | cut -f1 -d' ')"
	d="$(echo $kdtwhrs | cut -f2 -d' ')"
	t="$(echo $kdtwhrs | cut -f3 -d' ')"
	w="$(echo $kdtwhrs | cut -f4 -d' ')"
	h="$(echo $kdtwhrs | cut -f5 -d' ')"
	r="$(echo $kdtwhrs | cut -f6 -d' ')"
	s="$(echo $kdtwhrs | cut -f7 -d' ')"
	dev[$k]=$d
	config[source_format]=$t
	config[source_width]=$w
	config[source_height]=$h
	config[source_fps]=$r
fi

if [ ! -z "${config[source_fps]}" -a $(( ${config[fps]} )) -ne $(( ${config[source_fps]} )) ] ; then
	qmst=$(( (2000/${config[source_fps]}) + (1000/${config[fps]}) + 1 ))
fi
LOG DEBUG qmst@dev=$qmst

# RTMP to ${URL}/${SKEY}
# NB: it seems that one of the keys to getting audio/video interleaving is to put
#     the flvmux into its own gstreamer thread and not making it part of the video pipeline
#     Also, latency needs to be specified
if ${enable[rtmp]} ; then
	if [ -z "${USERNAME}" -o -z "${KEY}" ] ; then
		gst[avsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]} live=1 flashver=FME/3.0%20(compatible;%20FMSc%201.0)\""
	else
		gst[avsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]}?username=${USERNAME}&password=${KEY}\""
	fi
elif ${enable[udp]} ; then
	gst[avsink]="$(rtpmux) ! udpsink ${udp[props]}"
else
	# must instantiate a mux that has sink templates of .sink_0 and .sink_1 (like for UDP)
	gst[avsink]="$(rtpmux) ! fakesink"
fi

# audio devices
# NB: buffer management and sync can cause all kinds of problems including the dreaded
# ERROR                   rtmp :0:: WriteN, RTMP send error 104 (25 bytes)
# NB: in conjunction with flvmux in its own thread, it is also necessary to
#     add extra buffering after encoding the audio to allow the flvmux to
#     correctly match up the time.  This helps to avoid the above send errors.
# NB: devices constantly move around.  One cannot pick them, rather you have to choose from the list du-jour
if ${enable[audio]} ; then
	aplay -l | grep 'card.*device' | grep "${config[audio]}" | while read p || [[ -n $p ]] ; do
		# BEWARE: this is running in a separate shell, changes to the parent environment do not persist
		c=$(echo $p | cut -f1 -d, | cut -f1 -d: | cut -f2 -d' ')
		d=$(echo $p | cut -f2 -d, | cut -f1 -d: | cut -f3 -d' ')
		LOG TRY "hw:${c},${d}"
		gst-launch-1.0 -v alsasrc device="hw:${c},${d}" num-buffers=0 ! fakesink 2>&1 | sed -une '/src: caps/ s/[:;] /\n/gp' > /tmp/audio.$$
		if grep S16LE /tmp/audio.$$ > /dev/null && ${enable[audio]} ; then
			echo "hw:${c},${d}" > ${LOGDIR}/gst.audio.dev.$$
		fi
	done
	if x=$(cat ${LOGDIR}/gst.audio.dev.$$) ; then
		if [ -z "$x" ] ; then
			LOG NO audio ${config[audio]} because /tmp/audio.$$ had no suitable capabilities
		else
			dev[audio]="$x"
			LOG SELECT "${dev[audio]} for ${config[audio]}"
		fi
	else
		LOG NO audio ${config[audio]} because ${LOGDIR}/gst.audio.dev.$$ was not read
	fi
	# Determine which audio encoder we will use
	for e in $(IFS=',';echo ${config[audio_encoders]}) ; do
		LOG TRY $e
		if gst-inspect-1.0 $e >> $log ; then
			LOG SELECT $e
			x=$(echo S16LE | grep -E ${encoder_formats[$e]})
			if [ -z "$x" ] ; then
				gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! audioconvert ! ${encoder[$e]} ! aacparse ! $(timequeue $(($qmst * ${config[audmux_ratio]})))"
			else
				gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! ${encoder[$e]} ! aacparse ! $(timequeue $(($qmst * ${config[audmux_ratio]})))"
			fi
			if ${enable[rtmp]} ; then
				gst[audiopipeline]="${gst[audiopipeline]} ! mux.audio"
			else
				gst[audiopipeline]="${gst[audiopipeline]} ! rtpmp4apay pt=96 ! mux.sink_1"
			fi
			break
		fi
	done
else
	gst[audiopipeline]=""
fi
if [ -z "${gst[audiopipeline]}" ] ; then
	LOG NO Audio encoder available
fi

# TODO: determine which video source we will use.  Options are v4l2src (default), uvch264src/uvch264mjpgdemux (if installed) and imxv4l2videosrc (imx6)
function videosource {
	local result="v4l2src device=$2 io-mode=mmap"
	if [ "$1" == "test" ] ; then
		result="videotestsrc is-live=true"
		if ${enable[snow]} ; then result="$result pattern=snow" ; fi
	fi
	echo $result
}

function transformer {
	local result="videoconvert ! ${gst[videoscale]}"
	if [[ ${gst[videoscale]} =~ .*imxipuvideotransform.* ]] ; then
		# https://github.com/Freescale/gstreamer-imx/issues/27
		#result="${gst[videoscale]} ! $(xrawargs $1 $2 $3 Y444) ! videoconvert ! $(xrawargs $1 $2 $3 $4)"
		result="${gst[videoscale]} ! $(xrawargs $1 $2 $3 $4)"
	fi
	echo $result
}

# Determine source pipeline in priority: H264->MJPG->XRAW->TEST
if [ ! -z "${dev[h264]}" ] ; then
	sourceinfo="H.264 ${dev[h264]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource h264 ${dev[h264]})"
	# TODO: if enable[h265], it means we need to transcode h264->h265, which is silly, but if thats what is wanted...
	gst[encoder]=""
elif [ ! -z "${dev[mjpg]}" ] ; then
	sourceinfo="MJPG ${dev[mjpg]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource mjpg ${dev[mjpg]}) ! $(mjpgargs ${config[width]} ${config[height]} ${config[fps]}) ! jpegdec ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420)"
elif [ -z "${config[source_width]}" ] || [ -z "${config[source_height]}" ] ; then
	LOG NO Source available - test pipeline enabled
	sourceinfo="TEST ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource test) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420)"
	if ! ${enable[snow]} ; then gst[sourcepipeline]="${gst[sourcepipeline]} ! $(overlay ${config[width]} ${config[height]} ${config[fps]} overlay ${gst[encoder]})" ; fi
	gst[sourcepipeline]="${gst[sourcepipeline]}"
elif [ ! -z "${dev[xraw]}" ] ; then
	config_width=$(( ${config[width]} ))
	config_height=$(( ${config[height]} ))
	config_fps=$(( ${config[fps]} ))
	source_format=$(( ${config[source_format]} ))
	source_width=$(( ${config[source_width]} ))
	source_height=$(( ${config[source_height]} ))
	source_fps=$(( ${config[source_fps]} ))
	if [ $config_width -eq $source_width -a $config_height -eq $source_height -a $config_fps -eq $source_fps ] ; then
		sourceinfo="XRAW ${dev[xraw]} ${config[width]} ${config[height]} ${config[fps]}"
		if [[ ${gst[encoder]} =~ .*v4l2h264enc.* ]] ; then
			# for v4l2h264enc use, do not give I420 format to v4l2src
			gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]})"
		else
			gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420)"
		fi
		sourceinfo="XRAW ${dev[xraw]} ${config[width]} ${config[height]} ${config[fps]}"
	else
		gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[source_width]} ${config[source_height]} ${config[source_fps]} ${config[source_format]})"
		sourceinfo="XRAW ${dev[xraw]} (${config[source_format]} ${config[source_width]} ${config[source_height]} ${config[source_fps]}) -> (I420 ${config[width]} ${config[height]} ${config[fps]})"
		# for USB2.0, cameras cannot emit 1080p@30fps/720p@30fps so we pull 640x???@30fps and upscale
		if [ $source_fps -ne $config_fps ] ; then
			LOG SOURCE ${source_fps}/${config_fps} rate adjustment
			gst[videorate]="videorate max-rate=${config_fps} skip-to-first=true"
			gst[sourcepipeline]="${gst[sourcepipeline]} ! ${gst[videorate]}"
		fi
		# NB: videoconvert should negotiate optimally so a camera that can emit I420 will be slightly more efficient
		if [ $source_width -ne $config_width -o $source_height -ne $config_height ] ; then
			LOG SOURCE ${source_width}x${source_height}/${config_width}x${config_height} transform adjustment
			gst[sourcepipeline]="${gst[sourcepipeline]} ! $(transformer ${config[width]} ${config[height]} ${config[fps]} I420)"
		fi
		gst[sourcepipeline]="${gst[sourcepipeline]}"
	fi
else
	sourceinfo="TEST ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource test) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420)"
	if ! ${enable[snow]} ; then gst[sourcepipeline]="${gst[sourcepipeline]} ! $(overlay ${config[width]} ${config[height]} ${config[fps]} overlay ${gst[encoder]})" ; fi
	gst[sourcepipeline]="${gst[sourcepipeline]}"
fi


# perform a speedtest before launching the pipeline if so configured
if ${enable[wan]} && ${enable[speedtest]} ; then
	LOG DEBUG speedtest...
	x=$(/usr/local/bin/speedtest-cli --no-download --single --json)
	echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(json.dumps(x,indent=2))" >> $log
	# analyze upload kbps
	ul=$(echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(int(x['upload']))")
	min_ul=$((${config[kbps]} * 1100))  # 10% over minimum bit rate, in bps
	message="measured: $(($ul / 1000)) kbps, required: $(($min_ul / 1000)) kbps"
	if [[ $ul -lt $min_ul ]] ; then
		message="$message *** BELOW MIN"
	fi
	LOG INFO $message
else
	message="Upload speedtest/wan not selected"
fi

# 2nd Sink for diagnostics/file recording
if ${enable[preview]} ; then
	gst[filesink]="$(timequeue $qmst leaky=downstream) ! $(overlay ${config[width]} ${config[height]} ${config[fps]} message $message)"
	if ${enable[progressreport]} ; then gst[filesink]="${gst[filesink]} ! progressreport" ; fi
	gst[filesink]="${gst[filesink]} ! fpsdisplaysink sync=false video-sink=autovideosink"
elif ${enable[progressreport]} ; then
	gst[filesink]="$(timequeue $qmst leaky=downstream) ! progressreport ! fakesink"
fi

# Cast gstreamer spell
# http://gstreamer-devel.966125.n4.nabble.com/Does-Gstreamer-has-a-element-that-can-split-one-stream-into-two-td966351.html
# https://serverfault.com/a/975753
# https://stackoverflow.com/questions/59085054/gstreamer-issue-with-adding-timeoverlay-on-rtmp-stream
if ${enable[debug]} ; then
	gst[command]=""
	if ${enable[srcpipe]} ; then gst[command]="${gst[command]} ${gst[sourcepipeline]} !" ; fi
	if ${enable[encpipe]} ; then gst[command]="${gst[command]} ${gst[encoder]} ! $(encoder_args ${config[width]} ${config[height]} ${config[fps]}) !" ; fi
	if ${enable[snkpipe]} ; then gst[command]="${gst[command]} ${gst[avsink]}" ; fi
	# NB: this is the only place where stdout is written to, so that the output of this script is a gstreamer pipeline
	echo "${gst[command]}"
	exit 0
fi
gst[command]="gst-launch-1.0"
if [ -z "${gst[filesink]}" ] ; then
	gst[command]="${gst[command]} ${gst[sourcepipeline]} ! ${gst[encoder]} ! $(encoder_args ${config[width]} ${config[height]} ${config[fps]}) ! ${gst[avsink]} ${gst[audiopipeline]}"
else
	gst[command]="${gst[command]} ${gst[sourcepipeline]} ! ${gst[encoder]} ! $(encoder_args ${config[width]} ${config[height]} ${config[fps]}) ! tee name=t t. ! ${gst[avsink]} t. ! ${gst[filesink]} ${gst[audiopipeline]}"
fi
echo "${gst[command]}"  > ${LOGDIR}/gst.cmd.$$
LOG BEGIN $sourceinfo ${config[kbps]} kbps ${LOGDIR}/gst.cmd.$$
if ! source ${LOGDIR}/gst.cmd.$$ ; then
	exit 1
fi