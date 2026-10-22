# Ankle node firmware: Seeed XIAO nRF52840 Sense Plus, Arduino framework via arduino-cli.
#
#   make                 build the left node (default)
#   make ROLE=R          build the right node
#   make flash PORT=/dev/cu.usbmodemXXXX [ROLE=R]
#   make monitor PORT=/dev/cu.usbmodemXXXX
#   make CLASSIFIER=rules   use the rule classifier instead of the CNN
#
# A stored role (serial command `role L|R`) overrides the compile-time default,
# so one build can serve both nodes once each has been told which ankle it is.

FQBN      ?= Seeeduino:nrf52:xiaonRF52840SensePlus
ROLE      ?= L
CLASSIFIER?= cnn
PORT      ?=
BUILD     := build/$(ROLE)-$(CLASSIFIER)

DEFS := -DDT_FW_MAJOR=0 -DDT_FW_MINOR=2
ifeq ($(ROLE),R)
DEFS += -DDT_DEFAULT_ROLE_RIGHT
endif
ifeq ($(CLASSIFIER),rules)
DEFS += -DDT_CLASSIFIER_RULES
endif

# The core's post-build hooks call "python"; Homebrew's python@3.12 provides that name.
export PATH := /opt/homebrew/opt/python@3.12/libexec/bin:$(PATH)

PROPS := --build-property "compiler.c.extra_flags=$(DEFS)" --build-property "compiler.cpp.extra_flags=$(DEFS)"

.PHONY: all build flash monitor clean setup

all: build

build:
	arduino-cli compile --fqbn $(FQBN) $(PROPS) --build-path $(BUILD) --warnings default dance_node

flash: build
	@test -n "$(PORT)" || (echo "set PORT=/dev/cu.usbmodem..." && exit 1)
	arduino-cli upload --fqbn $(FQBN) --input-dir $(BUILD) -p $(PORT) dance_node

monitor:
	@test -n "$(PORT)" || (echo "set PORT=/dev/cu.usbmodem..." && exit 1)
	arduino-cli monitor -p $(PORT) -c baudrate=115200

clean:
	rm -rf build

# One-time toolchain install.
setup:
	arduino-cli config init --overwrite
	arduino-cli config set board_manager.additional_urls https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
	arduino-cli core update-index
	arduino-cli core install Seeeduino:nrf52
