# Automation boilerplate

SHELL := /bin/bash
SUDO := $(shell test $${EUID} -ne 0 && echo "sudo")
# https://stackoverflow.com/questions/41302443/in-makefile-know-if-gnu-make-is-in-dry-run
DRY_RUN := $(if $(findstring n,$(firstword -$(MAKEFLAGS))),--dry-run)
.EXPORT_ALL_VARIABLES:

PKGDEPS=sudo python3-netifaces python3-pip uvcdynctrl v4l-utils

LOCAL=/usr/local
LOCAL_APPS=gst-client gstd-client gst-client-1.0 gstd speedtest-cli
LOCAL_SCRIPTS=internet.py video-stream.sh stream-monitor.py
FLAGS ?= "h264,mjpg,rtmp,xraw"
LIBSYSTEMD=/lib/systemd/system
PLATFORM ?= $(shell python3 serial_number.py | cut -c1-4)
SERVER ?= video.mavnet.online
SERVER_PORT ?= 1935
SERVER_GROUP ?= live/ORNL
SERVICES=camera-switcher.service audio-streamer.service stream-monitor.service
SIVEL=https://github.com/sivel
SPEEDTEST=$(LOCAL)/bin/speedtest-cli
SPEEDTEST_SRC=$(LOCAL)/src/speedtest-cli
SYSCFG=/etc/systemd

.PHONY = clean dependencies disable enable git-cache install
.PHONY = provision provision-audio provision-cameras provision-video
.PHONY = show-config stop-cameras test uninstall

default:
	@echo "Please choose an action:"
	@echo ""
	@echo "  dependencies: ensure all needed software is installed (requires internet)"
	@echo "  install: update programs and system scripts"
	@echo "  provision: interactively define the needed configurations (all of them)"
	@echo ""
	@echo "The above are issued in the order shown above.  dependencies is only done once."
	@echo "Once the system is setup, you can use these two shortcuts to modify video parameters:"
	@echo ""
	@echo "  provision-audio: re-adjust audio streaming parameters"
	@echo "  provision-video: re-adjust video streaming parameters"
	@echo "  provision-cameras: re-assign cameras"
	@echo ""

$(LOCAL)/bin/audio-streamer.sh:
	$(SUDO) systemctl stop audio-streamer
	PLATFORM=$(PLATFORM) ./provision.sh $@ $(DRY_RUN)

$(LOCAL)/bin/camera-switcher.sh:
	$(SUDO) systemctl stop camera-switcher
	$(SUDO) install -Dm755 ./camera-switcher.sh $@

$(LOCAL)/src:
	@if [ ! -d $@ ] ; then mkdir -p $@ ; fi

$(SPEEDTEST_SRC): $(LOCAL)/src
	$(SUDO) chmod a+w $<
	@if [ ! -d $@ ] ; then cd $(dir $@) && git clone $(SIVEL)/$(notdir $@).git -b master ; fi

$(SPEEDTEST): $(SPEEDTEST_SRC)
	$(SUDO) install -Dm755 $</speedtest.py $@

$(SYSCFG)/%.conf:
	PLATFORM=$(PLATFORM) ./provision.sh $@ $(DRY_RUN)

# https://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
# TODO: figure out use of an encrypted filesystem to hold the configuration file
# https://www.linuxjournal.com/article/9400
# FIXME: this shell code in makefile is really, really dumb...
$(SYSCFG): serial_number.py

clean:
	/bin/true

dependencies:
	@if [ ! -z "$(PKGDEPS)" ] && [ -z "$(DRY_RUN)" ] ; then \
		$(SUDO) apt-get update ; \
		$(SUDO) apt-get install -y $(PKGDEPS) ; \
	fi
	@PLATFORM=$(PLATFORM) ./ensure-gst.sh $(DRY_RUN)
	@PLATFORM=$(PLATFORM) ./ensure-gstd.sh $(DRY_RUN)
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
	@for s in $(LOCAL_SCRIPTS) ; do $(SUDO) install -Dm755 $${s} $(LOCAL)/bin/$${s} ; done
	@for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done ; true
	@for s in $(SERVICES) ; do $(SUDO) install -Dm644 $${s%.*}.service $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi
	@for s in $(SERVICES) ; do $(SUDO) systemctl enable $${s%.*} ; done

provision:
	# NB: order is important in generating these files
	$(MAKE) --no-print-directory -B $(SYSCFG)/video-stream.conf $(DRY_RUN)
	@for s in $(SERVICES) ; do $(MAKE) --no-print-directory -B $(SYSCFG)/$${s%.*}.conf $(DRY_RUN) ; done
	$(MAKE) --no-print-directory -B $(LOCAL)/bin/camera-switcher.sh $(DRY_RUN)
	$(MAKE) --no-print-directory -B $(LOCAL)/bin/audio-streamer.sh $(DRY_RUN)
	$(SUDO) systemctl restart audio-streamer camera-switcher

provision-audio:
	$(MAKE) --no-print-directory -B $(SYSCFG)/audio-streamer.conf $(DRY_RUN)
	$(MAKE) --no-print-directory -B $(LOCAL)/bin/audio-streamer.sh $(DRY_RUN)
	$(SUDO) systemctl restart audio-streamer

provision-cameras:
	$(MAKE) --no-print-directory -B $(SYSCFG)/camera-switcher.conf $(DRY_RUN)
	$(MAKE) --no-print-directory -B $(LOCAL)/bin/camera-switcher.sh $(DRY_RUN)
	$(SUDO) systemctl restart camera-switcher

provision-video:
	$(MAKE) --no-print-directory -B $(SYSCFG)/video-stream.conf $(DRY_RUN)
	$(MAKE) --no-print-directory -B $(SYSCFG)/camera-switcher.conf $(DRY_RUN)
	$(MAKE) --no-print-directory -B $(LOCAL)/bin/camera-switcher.sh $(DRY_RUN)
	$(SUDO) systemctl restart camera-switcher

show-config:
	@for s in video-stream.service $(SERVICES) ; do echo "*** $${s%.*}.conf ***" && $(SUDO) cat $(SYSCFG)/$${s%.*}.conf ; done
	@echo "*** cameras ***" && ls -al /dev/cam*

stop-cameras:
	@for s in $(shell seq 1 3) ; do gst-client pipeline_stop cam$${s} ; done

cam%:
    $(MAKE) --no-print-directory -B stop-cameras
    gst-client pipeline_play $@

/etc/hosts: Makefile
	@(	URL=$(shell $(SUDO) grep URL $(SYSCFG)/video-stream.conf | cut -f2 -d=) && \
		if [ ! -z "$${URL}" -a "$${URL}" != "udp" ] ; then \
			SVR=$$(echo $$URL | cut -f2 -d: | sed -e 's/\/*//') && \
			read -p "Server for RTMP stream? ($${SVR}) " VS && \
			if [ ! -z "$${VS}" ] ; then SVR=$${VS} ; fi ; \
			if [ ! -z "$$SVR" ] ; then \
				python3 override.py $$SVR /etc/hosts ; \
			fi ; \
		fi )

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
	-( cd $(LOCAL)/bin && $(SUDO) rm $(LOCAL_APPS) $(LOCAL_SCRIPTS) )
	@-for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done
	@for s in $(SERVICES) ; do $(SUDO) rm $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi

