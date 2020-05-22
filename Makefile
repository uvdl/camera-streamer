# Automation boilerplate

SHELL := /bin/bash
SUDO := $(shell test $${EUID} -ne 0 && echo "sudo")
.EXPORT_ALL_VARIABLES:

PKGDEPS=automake host libtool pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev libjson-glib-dev gtk-doc-tools libreadline-dev libncursesw5-dev libdaemon-dev libjansson-dev sudo uvcdynctrl v4l-utils python3-netifaces python3-pip

LOCAL=/usr/local
LOCAL_APPS=gst-client gstd-client gst-client-1.0 gstd internet.py speedtest-cli video-stream.sh stream-monitor.py
FLAGS ?= "audio,h264,mjpg,rtmp,xraw"
GSTD=$(LOCAL)/bin/gstd
GSTD_SRC=$(LOCAL)/src/gstd-1.x
LIBSYSTEMD=/lib/systemd/system
PLATFORM ?= $(shell python3 serial_number.py | cut -c1-4)
RIDGERUN=https://github.com/RidgeRun
SERVER ?= video.mavnet.online
SERVER_PORT ?= 1935
SERVER_GROUP ?= live/ORNL
SERVICES=video-stream.service stream-monitor.service
SIVEL=https://github.com/sivel
SPEEDTEST=$(LOCAL)/bin/speedtest-cli
SPEEDTEST_SRC=$(LOCAL)/src/speedtest-cli
SYSCFG=/etc/systemd/video-stream.conf

.PHONY = clean dependencies disable enable git-cache install provision test uninstall

$(GSTD_SRC): $(LOCAL)/src
	$(SUDO) chmod a+w $<
	@if [ ! -d $@ ] ; then cd $(dir $@) && git clone $(RIDGERUN)/$(notdir $@).git -b develop ; fi

$(GSTD): $(GSTD_SRC)
	@( cd $(GSTD_SRC) && ./autogen.sh && ./configure && make )
	@( cd $(GSTD_SRC) && $(SUDO) make install )

$(LOCAL)/src:
	@if [ ! -d $@ ] ; then mkdir -p $@ ; fi

$(LOCAL)/bin/internet.py: internet.py
	$(SUDO) install -Dm755 $< $@

$(LOCAL)/bin/stream-monitor.py: stream-monitor.py
	$(SUDO) install -Dm755 $< $@

$(LOCAL)/bin/video-stream.sh: video-stream.sh
	$(SUDO) install -Dm755 $< $@

$(SPEEDTEST_SRC): $(LOCAL)/src
	$(SUDO) chmod a+w $<
	@if [ ! -d $@ ] ; then cd $(dir $@) && git clone $(SIVEL)/$(notdir $@).git -b master ; fi

$(SPEEDTEST): $(SPEEDTEST_SRC)
	$(SUDO) install -Dm755 $</speedtest.py $@

# https://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
# TODO: figure out use of an encrypted filesystem to hold the configuration file
# https://www.linuxjournal.com/article/9400
# FIXME: this shell code in makefile is really, really dumb...
$(SYSCFG): serial_number.py
	@(	SN=$(shell python3 serial_number.py) && \
		URL=$(shell $(SUDO) grep URL $(SYSCFG) | cut -f2 -d=) && \
		SKEY=$(shell $(SUDO) grep SKEY $(SYSCFG) | cut -f2 -d=) && \
		AUDIO=$(shell $(SUDO) grep AUDIO $(SYSCFG) | cut -f2 -d=) && \
		LATENCY_MS=$(shell $(SUDO) grep LATENCY_MS $(SYSCFG) | cut -f2 -d=) && \
		read -p "udp or URL for video server? ($${URL}) " UR && \
		if [ ! -z "$${UR}" ] ; then URL=$${UR} ; fi ; \
		if [ -z "$${SKEY}}" ] ; then SKEY=$${SN} ; fi ; \
		read -p "Stream Key? ($${SKEY}) " SK && \
		if [ ! -z "$${SK}" ] ; then SKEY=$${SK} ; fi ; \
		echo "[Service]" > /tmp/$$.env ; \
		x=$$(echo $$URL | grep mavnet.online) && \
		if [ ! -z "$$x" ] ; then \
			USERNAME=$(shell $(SUDO) grep USERNAME $(SYSCFG) | cut -f2 -d=) && \
			read -p "Username for video server? ($${USERNAME}) " UN && \
			if [ ! -z "$${UN}" ] ; then USERNAME=$${UN} ; fi ; \
			read -s -p "Password? " KEY ; echo "" ; \
			echo "KEY=$${KEY}" >> /tmp/$$.env && \
			echo "USERNAME=$${USERNAME}" >> /tmp/$$.env && \
			echo "SERVER=$${SERVER}" >> /tmp/$$.env && \
			SKEY="$${SN}" && \
			URL="rtmp://$${SERVER}:$${SERVER_PORT}/$${SERVER_GROUP}" ; \
		fi ; \
		if [ "$$URL" == "udp" ] ; then \
			FLAGS="audio,h264,mjpg,udp,xraw"
			UDP_IFACE=$(shell $(SUDO) grep UDP_IFACE $(SYSCFG) | cut -f2 -d=) && \
			UDP_HOST=$(shell $(SUDO) grep UDP_HOST $(SYSCFG) | cut -f2 -d=) && \
			UDP_PORT=$(shell $(SUDO) grep UDP_PORT $(SYSCFG) | cut -f2 -d=) && \
			read -p "Network interface device for udp ($${UDP_IFACE}) " UIF && \
			if [ ! -z "$${UIF}" ] ; then UDP_IFACE=$${UIF} ; fi ; \
			read -p "UDP port for video stream? ($${UDP_PORT}) " UP && \
			if [ ! -z "$${UP}" ] ; then UDP_PORT=$${UP} ; fi ; \
			read -p "UDP address for video stream? ($${UDP_HOST}) " UH && \
			if [ ! -z "$${UH}" ] ; then UDP_HOST=$${UH} ; fi ; \
			echo "UDP_IFACE=$${UDP_IFACE}" >> /tmp/$$.env && \
			echo "UDP_HOST=$${UDP_HOST}" >> /tmp/$$.env && \
			echo "UDP_PORT=$${UDP_PORT}" >> /tmp/$$.env ; \
		fi ; \
		echo "URL=$${URL}" >> /tmp/$$.env && \
		echo "SKEY=$${SKEY}" >> /tmp/$$.env && \
		echo "FLAGS=$(FLAGS)" >> /tmp/$$.env && \
		read -p "Audio Device? ($${AUDIO}) " ADEV && \
		if [ ! -z "$${ADEV}" ] ; then AUDIO="$${ADEV}" ; fi ; \
		echo "AUDIO=$${AUDIO}" >> /tmp/$$.env && \
		read -p "Override Latency (ms)? ($${LATENCY_MS}) " LMS && \
		if [ ! -z "$${LMS}" ] ; then LATENCY_MS=$${LMS} ; fi ; \
		echo "LATENCY_MS=$${LATENCY_MS}" >> /tmp/$$.env && \
		echo "PLATFORM=$(PLATFORM)" >> /tmp/$$.env && \
		$(SUDO) install -Dm600 /tmp/$$.env $@ ; \
		rm /tmp/$$.env )

clean:
	/bin/true

dependencies:
	$(SUDO) apt-get update
	@PLATFORM=$(PLATFORM) ./ensure-gst.sh --dry-run
	$(SUDO) apt-get install -y $(PKGDEPS)
	$(MAKE) --no-print-directory $(GSTD)
	$(MAKE) --no-print-directory $(SPEEDTEST)

disable:
	# https://lunar.computer/posts/nvidia-jetson-nano-headless/
	@for c in stop disable ; do $(SUDO) systemctl $$c gdm3 ; done
	$(SUDO) systemctl set-default multi-user.target

enable:
	# https://lunar.computer/posts/nvidia-jetson-nano-headless/
	$(SUDO) systemctl set-default graphical.target
	@for c in enable start ; do $(SUDO) systemctl $$c gdm3 ; done

git-cache:
	git config --global credential.helper "cache --timeout=5400"

install: git-cache
	$(MAKE) --no-print-directory $(GSTD) $(LOCAL)/bin/video-stream.sh $(LOCAL)/bin/stream-monitor.py $(LOCAL)/bin/internet.py $(SPEEDTEST)
	@for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done ; true
	@for s in $(SERVICES) ; do $(SUDO) install -Dm644 $${s%.*}.service $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi
	@for s in $(SERVICES) ; do $(SUDO) systemctl enable $${s%.*} ; done

provision:
	$(MAKE) --no-print-directory FLAGS=$(FLAGS) -B $(SYSCFG)
	$(MAKE) --no-print-directory -B /etc/hosts
	@(	UDP_IFACE=$(shell $(SUDO) grep UDP_IFACE $(SYSCFG) | cut -f2 -d=) && \
		UDP_IFACE=$$UDP_IFACE $(MAKE) --no-print-directory -B /etc/network/interfaces )

/etc/hosts: Makefile
	@(	URL=$(shell $(SUDO) grep URL $(SYSCFG) | cut -f2 -d=) && \
		if [ ! -z "$${URL}" -a "$${URL}" != "udp" ] ; then \
			SVR=$$(echo $$URL | cut -f2 -d: | sed -e 's/\/*//') && \
			read -p "Server for RTMP stream? ($${SVR}) " VS && \
			if [ ! -z "$${VS}" ] ; then SVR=$${VS} ; fi ; \
			if [ ! -z "$$SVR" ] ; then \
				python3 override.py $$SVR /etc/hosts ; \
			fi ; \
		fi )

/etc/network/interfaces: Makefile
	@(	UDP_ADDR=$(shell ip addr show $${UDP_IFACE} | grep inet | grep -v inet6 | head -1 | sed -e 's/^[[:space:]]*//' | cut -f2 -d' ' | cut -f1 -d/) && \
		read -p "IPv4 Address for $${UDP_IFACE}? ($${UDP_ADDR}) " UA && \
		if [ ! -z "$${UA}" ] ; then UDP_ADDR=$${UA} ; fi ; \
		python3 override.py "$${UDP_ADDR}" $@ )

test:
	-@( gstd -k && gstd )
	gst-client pipeline_create testpipe videotestsrc name=vts ! autovideosink
	gst-client pipeline_play testpipe && sleep 5
	gst-client element_set testpipe vts pattern ball && sleep 5
	gst-client pipeline_stop testpipe
	gst-client pipeline_delete testpipe
	@gstd -k

uninstall:
	-@gstd -k
	-( cd $(LOCAL)/bin && $(SUDO) rm $(LOCAL_APPS) )
	@-for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done
	@for s in $(SERVICES) ; do $(SUDO) rm $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi

