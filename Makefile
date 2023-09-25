SHELL=/bin/bash
BUILDREPO=https://github.com/vyos/vyos-build

ARCH=amd64
BUILDER=xrobau@gmail.com
RELEASE=1.4-$(shell date -u '+%Y-%m-%d')

help: vyos-build/.git/config
	@echo 'make iso:          Builds a VyOS iso '
	@echo 'make docker:       Build the docker container only'
	@echo 'make redocker:     Forces a rebuild of the docker contane'
	@echo 'make forcedocker:  Forces a rebuild of the docker contaner, disabling'
	@echo '                   the docker build cache.'
	@echo 'make update:       Updates the vyos-build repo'
	@echo 'make clean:        Asks the vyos-build repo to clean itself up'
	@echo 'make distclean:    Deletes everything, does not ask'
	@echo ''
	@echo 'Usage: `make update` and then `make iso` is usually sufficient for everything'


DOCKERCMD=docker run --rm -it --privileged -v $(shell pwd)/vyos-build:/vyos -w /vyos vyos/vyos-build:current

USECACHE=
forcedocker: USECACHE=--no-cache
forcedocker: redocker

.PHONY: docker
docker: .dockerbuild

.PHONY: redocker
# note 'zt' and 'vbash' are patches applied to the live chroot, below
redocker .dockerbuild: vyos-build/.git/config vyos-build/docker/Dockerfile zt vbash
	cd vyos-build && docker build $(USECACHE) -t vyos/vyos-build:current docker
	touch .dockerbuild

zt: vyos-build/data/live-build-config/hooks/live/50-zerotier.chroot
vbash: vyos-build/data/live-build-config/hooks/live/55-fix-vbash.chroot

iso: .dockerbuild
	$(DOCKERCMD) ./build-vyos-image --architecture $(ARCH) --build-by "$(BUILDER)" --version $(RELEASE) --build-type release --custom-package vyos-1x-smoketest iso

clean: .dockerbuild
	$(DOCKERCMD) make clean

vyos-build/data/live-build-config/hooks/live/%.chroot: ./%.chroot
	cp $< $@

vyos-build/.git/config:
	git clone $(BUILDREPO)

update: vyos-build/.git/config
	cd vyos-build && git pull

distclean:
	rm -rf .dockerbuild vyos-build

# Debugging inside the docker-build container
shell: .dockerbuild
	$(DOCKERCMD) bash

