SHELL=/bin/bash
BUILDREPO=https://github.com/vyos/vyos-build

# Anything in the current directory called *.chroot will be added to the
# live hooks to patch the default build
PATCHES=$(wildcard *.chroot)

ARCH=amd64
BUILDER=xrobau@gmail.com

RELEASE=1.4-$(shell date -u '+%Y-%m-%d')
BUILDDIR=vyos-build/build
RELEASEDIR=releases/$(RELEASE)
ISOFILE=vyos-$(RELEASE)-$(ARCH).iso
SRCISO=$(BUILDDIR)/$(ISOFILE)
DOCKERCMD=docker run --rm -it --privileged -v $(shell pwd)/vyos-build:/vyos -w /vyos vyos/vyos-build:current
LIVEPATCHES=$(addprefix vyos-build/data/live-build-config/hooks/live/,$(PATCHES))

help: vyos-build/.git/config
	@echo 'Usage:'
	@echo ''
	@echo '  `make update` and then `make release` is usually sufficient for everything'
	@echo '  If nothing has changed in the vyos-build repo, but other packages have been'
	@echo '  updated, use `make iso` to ensure the build ISO has the latest packages, as'
	@echo '  `make release` will not be aware of them and not trigger a rebuild.'
	@echo ''
	@echo 'make update:       Updates the vyos-build repo'
	@echo 'make iso:          Builds a VyOS iso'
	@echo 'make release:      Builds everything, and puts it all in $(RELEASEDIR)'
	@echo 'make clean:        Asks the vyos-build repo to clean itself up'
	@echo 'make distclean:    Deletes everything, does not ask'
	@echo ''
	@echo 'Other tools:'
	@echo 'make iso:          Builds a VyOS iso, even if it already exists'
	@echo 'make docker:       Build the docker container only'
	@echo 'make redocker:     Forces a rebuild of the docker contaner'
	@echo 'make forcedocker:  Forces a rebuild of the docker contaner, disabling'
	@echo '                   the docker build cache.'
	@echo 'make shell:        Launches a shell in the docker build container'
	@echo 'make debug:        Launches a shell in the built chroot. Be careful to'
	@echo '                   make sure everything is correctly unmounted on exit'
	@echo ''

USECACHE=
.PHONY: forcedocker
forcedocker: USECACHE=--no-cache
forcedocker: redocker

.PHONY: docker
docker: .dockerbuild

.PHONY: redocker
redocker .dockerbuild: vyos-build/.git/config vyos-build/docker/Dockerfile
	cd vyos-build && docker build $(USECACHE) -t vyos/vyos-build:current docker
	touch .dockerbuild

.PHONY: release
release: $(RELEASEDIR) $(RELEASEDIR)/$(ISOFILE) $(RELEASEDIR)/raw.packages $(RELEASEDIR)/build.log $(RELEASEDIR)/dpkg.dump
	@ls -al $(RELEASEDIR)/*

.PHONY: debug
debug: vyos-build/build/chroot
	@mount -t proc none $</proc
	@mount -t sysfs none $</sys
	@mount -t devtmpfs  none $</dev
	@mount -t devpts  none $</dev/pts
	chroot $< /bin/bash || :
	@umount $</proc $</sys $</dev/pts $</dev
	@echo "If this errors with  'not mounted', it's not a problem, as it is auto-mounted when you try to use networking"
	umount $</run/cgroup2 || :

$(RELEASEDIR)/dpkg.dump:
	@chroot $(BUILDDIR)/chroot dpkg -l > $@

$(RELEASEDIR)/$(ISOFILE): $(SRCISO)
	@cp $< $@

$(RELEASEDIR)/raw.packages: $(BUILDDIR)/live-image-$(ARCH).packages
	@cp $< $@

$(RELEASEDIR)/build.log: $(BUILDDIR)/build.log
	@cp $< $@

$(RELEASEDIR):
	@mkdir -p $@

.PHONY: iso
iso $(SRCISO): .dockerbuild $(LIVEPATCHES)
	@mkdir -p $(BUILDDIR)
	$(DOCKERCMD) ./build-vyos-image --architecture $(ARCH) --build-by "$(BUILDER)" --version $(RELEASE) --build-type release --custom-package vyos-1x-smoketest iso | tee $(BUILDDIR)/build.log

vyos-build/data/live-build-config/hooks/live/%: ./%
	@echo Updating $@
	@cp $< $@

vyos-build/.git/config:
	git clone $(BUILDREPO)

.PHONY: update
update: vyos-build/.git/config
	cd vyos-build && git pull

.PHONY: clean
clean: .dockerbuild
	$(DOCKERCMD) make clean
	rm -rf $(RELEASEDIR)

.PHONY: distclean
distclean:
	rm -rf .dockerbuild vyos-build releases

# Debugging inside the docker-build container
.PHONY: shell
shell: .dockerbuild
	$(DOCKERCMD) bash

