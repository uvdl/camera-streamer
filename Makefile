# Automation boilerplate

SHELL := /bin/bash
SUDO := $(shell test $${EUID} -ne 0 && echo "sudo")
.EXPORT_ALL_VARIABLES:

PKGDEPS=automake libtool pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev libjson-glib-dev gtk-doc-tools libreadline-dev libncursesw5-dev libdaemon-dev libjansson-dev

GSTD_BIN=/usr/local/bin
GSTD=$(GSTD_BIN)/gstd
GSTD_APPS=gst-client gstd-client gst-client-1.0 gstd
GSTD_SRC=$(HOME)/src/gstd-1.x
LIBSYSTEMD=/lib/systemd/system
RIDGERUN=https://github.com/RidgeRun
SERVICES=video-stream.service

.PHONY = clean deps disable enable git-cache install test uninstall

$(GSTD_SRC): $(HOME)/src
	@if [ ! -d $@ ] ; then cd $(dir $@) && git clone $(RIDGERUN)/$(notdir $@).git -b develop ; fi

$(GSTD): $(GSTD_SRC)
	@( cd $(GSTD_SRC) && ./autogen.sh && ./configure && make )
	@( cd $(GSTD_SRC) && $(SUDO) make install )

$(HOME)/src:
	@if [ ! -d $@ ] ; then mkdir -p $@ ; fi

clean:
	/bin/true

deps:
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

install: git-cache deps
	$(MAKE) --no-print-directory $(GSTD)
	@-for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done
	@for s in $(SERVICES) ; do $(SUDO) install -Dm644 $${s%.*}.service $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi
	@for s in $(SERVICES) ; do $(SUDO) systemctl enable $${s%.*} ; done

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
	-( cd $(GSTD_BIN) && $(SUDO) rm $(GSTD_APPS) )
	@-for c in stop disable ; do $(SUDO) systemctl $${c} $(SERVICES) ; done
	@for s in $(SERVICES) ; do $(SUDO) rm $(LIBSYSTEMD)/$${s%.*}.service ; done
	@if [ ! -z "$(SERVICES)" ] ; then $(SUDO) systemctl daemon-reload ; fi

