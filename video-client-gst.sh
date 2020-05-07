#!/bin/bash
# usage:
#   video-client-gst.sh [VPORT [APORT [IP [IFACE]]]]
#
# where:
#   VPORT, APORT: are integers describing the desired UDP PORT for (V)ideo and (A)udio
#   IP: is a string 
#   URL: overrides the stream URL in the config file
#   SKEY: overrides the stream key in the config file
#   FLAGS: overrides a list of flags to enable
#     audio - enable audio source multiplexing
#     debug - perform a dry-run and only report the pipeline that would be executed
#     rtmp - enable rtmp output to the internet
#     h264 - prefer H.264 source from camera
#     mjpg - fallback to Motion JPEG
#     udp - enable UDP output to LAN
#     xraw - fallback to RAW video (NB: may be bandwidth limited if using USB)
#
declare -A config
# https://stackoverflow.com/questions/31758480/modify-global-variable-array-through-a-bash-function-passing-the-function-the-n
# NB: currently cannot make this work
##function argument {
##	#config[$2]=$3
##	#if [ -z "${config[$2]}" ] ; then config[$2]=$4 ; fi
##	printf -v "$1[$2]" '%s' $3
##	if [ -z "$1[$2]" ] ; then printf -v "$1[$2]" '%s' $4 ; fi
##}
##$(argument config video_port $1 5600)
config[video_port]="$1" ; if [ -z "${config[video_port]}" ] ; then config[video_port]=5600 ; fi
config[audio_port]="$2" ; if [ -z "${config[audio_port]}" ] ; then config[audio_port]=0 ; fi
config[udp_ip]="$3"
config[mcast_if]="$4" ; if [ -z "${config[mcast_if]}" ] ; then config[mcast_if]=eth0 ; fi
config[video_caps]="application/x-rtp,media=(string)video,clock-rate=(int)90000,encoding-name=(string)H264,payload=(int)96"
config[audio_caps]="application/x-rtp"

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
	gst-launch-1.0 ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
elif [ ${config[audio_port]/.*} -eq 0 ] ; then
	# video only
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! rtph264depay ! h264parse ! queue ! decodebin ! progressreport ! autovideosink
elif [ ${config[audio_port]/.*} -eq ${config[video_port]/.*} ] ; then
	# video+audio using same port (flvmux)
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} ! queue ! flvdemux name=mux mux.video ! "${config[video_caps]}" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink mux.audio ! "${config[audio_caps]}" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
elif ${config[async]} ; then
	# video+audio using separate ports and separate processes
	# https://unix.stackexchange.com/questions/204480/run-multiple-commands-and-kill-them-as-one-in-bash
	# https://stackoverflow.com/questions/3004811/how-do-you-run-multiple-programs-in-parallel-from-a-bash-script
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink & gst-launch-1.0 ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink && fg
else
	# video+audio using separate ports and the same process (forces sync)
	set -x
	gst-launch-1.0 ${gst[udpsrc]} port=${config[video_port]} caps="${config[video_caps]}" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink ${gst[udpsrc]} port=${config[audio_port]} caps="${config[audio_caps]}" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
fi
