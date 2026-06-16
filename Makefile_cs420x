ifdef KERNELRELEASE
	KERNELDIR := /lib/modules/$(KERNELRELEASE)
else
	KERNELDIR := /lib/modules/$(shell uname -r)
endif

KERNELBUILD := $(KERNELDIR)/build

all:
	make -C $(KERNELBUILD) M=$(shell pwd)/build/hda/codecs/cirrus modules

clean:
	make -C $(KERNELBUILD) M=$(shell pwd)/build/hda/codecs/cirrus clean

ifndef KERNELRELEASE
install:
	cp $(shell pwd)/build/hda/codecs/cirrus/snd-hda-codec-cs420x.ko $(KERNELDIR)/updates
	depmod -a
endif
