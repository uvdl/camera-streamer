#!/bin/bash
# usage:
#   video-client-gst.sh [VPORT [APORT [IP [ENCD [IFACE]]]]]
#{
# where:
#   VPORT, APORT: are integers describing the desired UDP PORT for (V)ideo and (A)udio
#   IP: is a string of the IPv4 address to listen to (multicast range aware)
#   ENCD: define the expected video encoding (H264 or H265)
#   IFACE: define the local network interface to use for multicast IP (eth0, etc.)
#
declare -A config
config[video_port]="$1" ; if [ -z "${config[video_port]}" ] ; then config[video_port]=5600 ; fi
config[audio_port]="$2" ; if [ -z "${config[audio_port]}" ] ; then config[audio_port]=0 ; fi
config[udp_ip]="$3"
config[video_encd]="$4" ; if [ -z "${config[video_encd]}" ] ; then config[video_encd]=H264 ; fi
config[mcast_if]="$5" ; if [ -z "${config[mcast_if]}" ] ; then config[mcast_if]=eth0 ; fi
config[audio_caps]="application/x-rtp"
config[video_caps]="application/x-rtp,media=(string)video,clock-rate=(int)90000,encoding-name=(string)${config[video_encd]},payload=(int)96"
# Audio buffer is based on the AAC encoder channels: 1208=1 channel, 1210=2 channel
config[audio_depay]="rtpmp4adepay ! \"audio/mpeg,codec_data=(buffer)1208\" ! queue"
if [ "${config[video_encd]}" == "H265" ] ; then
	config[video_depay]="rtph265depay ! h265parse ! queue"
else
	config[video_depay]="rtph264depay ! h264parse ! queue"
fi

declare -A gst
if [ -z "${config[udp_ip]}" ] ; then
	# Agnostic source semantics
	gst[udpsrc]="udpsrc"
elif [ ${config[udp_ip]/.*} -ge 224 -a ${config[udp_ip]/.*} -le 239 ] ; then
	# Multicast source semantics
	gst[udpsrc]="udpsrc address=${config[udp_ip]} multicast-iface=${config[mcast_if]} auto-multicast=true"
else
	# Unicast source semantics
	gst[udpsrc]="udpsrc address=${config[udp_ip]}"
fi

# launch different spells depending on the balance of video/audio port
if [ ${config[video_port]/.*} -eq 0 -a ${config[audio_port]/.*} -eq 0 ] ; then
	# run test pattern generation to test installation
	set -x
	gst-launch-1.0 videotestsrc is-live=true ! "video/x-raw,format=(string)I420,width=(int)640,height=(int)360,framerate=30/1" ! videoconvert ! autovideosink
elif [ ${config[video_port]/.*} -eq 0 ] ; then
	# audio only
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! ${config[audio_depay]} ! decodebin ! audioconvert ! autoaudiosink
elif [ ${config[audio_port]/.*} -eq 0 ] ; then
	# video only
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! ${config[video_depay]} ! decodebin ! progressreport ! autovideosink
elif [ ${config[audio_port]/.*} -eq ${config[video_port]/.*} ] ; then
	# video+audio using same port (flvmux)
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} ! queue ! flvdemux name=mux mux.video ! "${config[video_caps]}" ! ${config[video_depay]} ! decodebin ! autovideosink mux.audio ! "${config[audio_caps]}" ! ${config[audio_depay]} ! decodebin ! audioconvert ! autoaudiosink
elif ${config[async]} ; then
	# video+audio using separate ports and separate processes
	# https://unix.stackexchange.com/questions/204480/run-multiple-commands-and-kill-them-as-one-in-bash
	# https://stackoverflow.com/questions/3004811/how-do-you-run-multiple-programs-in-parallel-from-a-bash-script
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! ${config[video_depay]} ! decodebin ! autovideosink & gst-launch-1.0 ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! ${config[audio_depay]} ! decodebin ! audioconvert ! autoaudiosink && fg
else
	# video+audio using separate ports and the same process (forces sync)
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! ${config[video_depay]} ! decodebin ! autovideosink ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! ${config[audio_depay]} ! decodebin ! audioconvert ! autoaudiosink
fi
