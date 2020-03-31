# Automation boilerplate

SHELL := /bin/bash
SUDO := $(shell test $${EUID} -ne 0 && echo "sudo")
.EXPORT_ALL_VARIABLES:

PKGDEPS=automake libtool pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev libjson-glib-dev gtk-doc-tools libreadline-dev libncursesw5-dev libdaemon-dev libjansson-dev uvcdynctrl v4l-utils python3-pip

LOCAL=/usr/local
LOCAL_APPS=gst-client gstd-client gst-client-1.0 gstd
FLAGS ?= "h264,mjpg,rtmp"
GSTD=$(LOCAL)/bin/gstd
GSTD_SRC=$(LOCAL)/src/gstd-1.x
LIBSYSTEMD=/lib/systemd/system
RIDGERUN=https://github.com/RidgeRun
SERVER ?= mavnet.online
SERVER_PORT ?= 1935
SERVER_GROUP ?= live/ORNL
SERVICES=video-stream.service
SYSCFG=/etc/systemd/rtmp-env.conf

.PHONY = clean dependencies disable enable git-cache install provision test uninstall

$(GSTD_SRC): $(LOCAL)/src
	@if [ ! -d $@ ] ; then cd $(dir $@) && git clone $(RIDGERUN)/$(notdir $@).git -b develop ; fi

$(GSTD): $(GSTD_SRC)
	@( cd $(GSTD_SRC) && ./autogen.sh && ./configure && make )
	@( cd $(GSTD_SRC) && $(SUDO) make install )

$(LOCAL)/src:
	@if [ ! -d $@ ] ; then mkdir -p $@ ; fi

$(LOCAL)/bin/video-stream.sh: video-stream.sh
	$(SUDO) install -Dm755 $< $@

# https://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
# TODO: figure out use of an encrypted filesystem to hold the configuration file
# https://www.linuxjournal.com/article/9400
$(SYSCFG): serial_number.py
	@(	SN=$(shell python serial_number.py) && \
		USERNAME=$(shell $(SUDO) grep USERNAME $(SYSCFG) | cut -f2 -d=) && \
		read -p "Username for video server? ($${USERNAME}) " UNAME && \
		if [ ! -z "$${UNAME}" ] ; then USERNAME=$${UNAME} ; fi ; \
		read -s -p "Password? " KEY ; \
		echo "[Service]" > /tmp/$$.env && \
		echo "FLAGS=$(FLAGS)" >> /tmp/$$.env && \
		echo "GROUP=$(SERVER_GROUP)" >> /tmp/$$.env && \
		echo "KEY=$${KEY}" >> /tmp/$$.env && \
		echo "PORT=$(SERVER_PORT)" >> /tmp/$$.env && \
		echo "SERVER=$(SERVER)" >> /tmp/$$.env && \
		echo "SN=$${SN}" >> /tmp/$$.env && \
		echo "USERNAME=$${USERNAME}" >> /tmp/$$.env && \
		$(SUDO) install -Dm600 /tmp/$$.env $@ ; \
		rm /tmp/$$.env )

clean:
	/bin/true

dependencies:
	$(SUDO) apt-get update
	$(SUDO) apt-get install -y $(PKGDEPS)
	$(MAKE) --no-print-directory $(GSTD)

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
	$(MAKE) --no-print-directory $(GSTD) $(LOCAL)/bin/video-stream.sh
	@-for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done
	@for s in $(SERVICES) ; do $(SUDO) install -Dm644 $${s%.*}.service $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi
	@for s in $(SERVICES) ; do $(SUDO) systemctl enable $${s%.*} ; done

provision:
	$(MAKE) --no-print-directory FLAGS=$(FLAGS) -B $(SYSCFG)

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

