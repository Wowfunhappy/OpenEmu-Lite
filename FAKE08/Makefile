# FAKE08 OpenEmu Core Plugin Makefile
# Builds FAKE08.oecoreplugin bundle for OpenEmu-Lite

# Paths
FAKE08_DIR := fake-08
SOURCE_DIR := $(FAKE08_DIR)/source
LIBS_DIR := $(FAKE08_DIR)/libs
BUILD_DIR := build
PLUGIN_NAME := FAKE08
PLUGIN_BUNDLE := $(PLUGIN_NAME).oecoreplugin

# Find the OpenEmuBase framework from the workspace build products
DERIVED_DATA_BASE := $(HOME)/Library/Developer/Xcode/DerivedData
OE_BUILD_DIR := $(shell find "$(DERIVED_DATA_BASE)" -path "*/OpenEmu-*/Build/Products/Release/OpenEmuBase.framework" -print -quit 2>/dev/null | sed 's|/OpenEmuBase.framework||')
ifeq ($(OE_BUILD_DIR),)
$(error OpenEmuBase.framework not found. Build OpenEmu-Lite from Xcode first.)
endif

# Compilers
CC := clang
CXX := clang++
OBJCXX := clang++

# SDK
SDKROOT := $(shell xcrun --show-sdk-path)

# Include paths
INCLUDES := -I$(SOURCE_DIR) \
            -I$(LIBS_DIR)/z8lua \
            -I$(LIBS_DIR)/lodepng \
            -I$(LIBS_DIR)/miniz \
            -I$(LIBS_DIR)/simpleini \
            -I. \
            -I../OpenEmu/PICO8 \
            -F$(OE_BUILD_DIR)

# Common flags
COMMON_FLAGS := -mmacosx-version-min=10.7 -stdlib=libc++ -isysroot $(SDKROOT) $(INCLUDES) -DMINIZ_NO_TIME -include compat.h

# z8lua headers use C++ (cstdint), so all C files must be compiled as C++
# This matches the libretro Makefile approach: CC = $(CXX)
CFLAGS := $(COMMON_FLAGS) -std=gnu++11 -fno-rtti -fvisibility=hidden
CXXFLAGS := $(COMMON_FLAGS) -std=gnu++11 -fno-rtti -fvisibility=hidden
OBJCXXFLAGS := $(COMMON_FLAGS) -std=gnu++11 -fobjc-arc -fvisibility=hidden -fvisibility-inlines-hidden

# Optimization
ifdef DEBUG
CFLAGS += -g -O0
CXXFLAGS += -g -O0
OBJCXXFLAGS += -g -O0
else
CFLAGS += -O2
CXXFLAGS += -O2
OBJCXXFLAGS += -O2
endif

# Linker flags
LDFLAGS := -bundle \
           -mmacosx-version-min=10.7 \
           -stdlib=libc++ \
           -isysroot $(SDKROOT) \
           -F$(OE_BUILD_DIR) \
           -framework OpenEmuBase \
           -framework Cocoa \
           -framework OpenGL \
           -framework Foundation \
           -lz \
           -lc++ \
           -Wl,-rpath,@executable_path/../Frameworks

# z8lua C sources
Z8LUA_SRCS := $(LIBS_DIR)/z8lua/eris.c \
              $(LIBS_DIR)/z8lua/lapi.c \
              $(LIBS_DIR)/z8lua/lauxlib.c \
              $(LIBS_DIR)/z8lua/lbaselib.c \
              $(LIBS_DIR)/z8lua/lbitlib.c \
              $(LIBS_DIR)/z8lua/lcode.c \
              $(LIBS_DIR)/z8lua/lcorolib.c \
              $(LIBS_DIR)/z8lua/lctype.c \
              $(LIBS_DIR)/z8lua/ldblib.c \
              $(LIBS_DIR)/z8lua/ldebug.c \
              $(LIBS_DIR)/z8lua/ldo.c \
              $(LIBS_DIR)/z8lua/ldump.c \
              $(LIBS_DIR)/z8lua/lfunc.c \
              $(LIBS_DIR)/z8lua/lgc.c \
              $(LIBS_DIR)/z8lua/linit.c \
              $(LIBS_DIR)/z8lua/liolib.c \
              $(LIBS_DIR)/z8lua/llex.c \
              $(LIBS_DIR)/z8lua/lmem.c \
              $(LIBS_DIR)/z8lua/loadlib.c \
              $(LIBS_DIR)/z8lua/lobject.c \
              $(LIBS_DIR)/z8lua/lopcodes.c \
              $(LIBS_DIR)/z8lua/loslib.c \
              $(LIBS_DIR)/z8lua/lparser.c \
              $(LIBS_DIR)/z8lua/lpico8lib.c \
              $(LIBS_DIR)/z8lua/lstate.c \
              $(LIBS_DIR)/z8lua/lstring.c \
              $(LIBS_DIR)/z8lua/lstrlib.c \
              $(LIBS_DIR)/z8lua/ltable.c \
              $(LIBS_DIR)/z8lua/ltablib.c \
              $(LIBS_DIR)/z8lua/ltests.c \
              $(LIBS_DIR)/z8lua/ltm.c \
              $(LIBS_DIR)/z8lua/lundump.c \
              $(LIBS_DIR)/z8lua/lvm.c \
              $(LIBS_DIR)/z8lua/lzio.c

# Other C sources
OTHER_C_SRCS := $(LIBS_DIR)/simpleini/ConvertUTF.c \
                $(LIBS_DIR)/miniz/miniz.c \
                LuaArena.c

# C++ sources
CXX_SRCS := $(LIBS_DIR)/lodepng/lodepng.cpp \
            $(SOURCE_DIR)/Audio.cpp \
            $(SOURCE_DIR)/Input.cpp \
            $(SOURCE_DIR)/cart.cpp \
            $(SOURCE_DIR)/emojiconversion.cpp \
            $(SOURCE_DIR)/filehelpers.cpp \
            $(SOURCE_DIR)/filter.cpp \
            $(SOURCE_DIR)/fontdata.cpp \
            $(SOURCE_DIR)/graphics.cpp \
            $(SOURCE_DIR)/hostCommonFunctions.cpp \
            $(SOURCE_DIR)/logger.cpp \
            $(SOURCE_DIR)/mathhelpers.cpp \
            $(SOURCE_DIR)/nibblehelpers.cpp \
            $(SOURCE_DIR)/picoluaapi.cpp \
            $(SOURCE_DIR)/printHelper.cpp \
            $(SOURCE_DIR)/stringToDataHelpers.cpp \
            $(SOURCE_DIR)/synth.cpp \
            $(SOURCE_DIR)/vm.cpp \
            OEHost.cpp

# Objective-C++ sources
OBJCXX_SRCS := PICO8GameCore.mm

# Object files
C_OBJS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(Z8LUA_SRCS) $(OTHER_C_SRCS))
CXX_OBJS := $(patsubst %.cpp,$(BUILD_DIR)/%.o,$(CXX_SRCS))
OBJCXX_OBJS := $(patsubst %.mm,$(BUILD_DIR)/%.o,$(OBJCXX_SRCS))
ALL_OBJS := $(C_OBJS) $(CXX_OBJS) $(OBJCXX_OBJS)

# Targets
.PHONY: all clean install

all: $(PLUGIN_BUNDLE)

$(PLUGIN_BUNDLE): $(BUILD_DIR)/$(PLUGIN_NAME) Info.plist
	@mkdir -p "$@/Contents/MacOS"
	@mkdir -p "$@/Contents/Resources"
	@cp $(BUILD_DIR)/$(PLUGIN_NAME) "$@/Contents/MacOS/$(PLUGIN_NAME)"
	@cp Info.plist "$@/Contents/Info.plist"
	@echo "Built $@"

$(BUILD_DIR)/$(PLUGIN_NAME): $(ALL_OBJS)
	@mkdir -p $(dir $@)
	$(CXX) $(LDFLAGS) -o $@ $^
	@echo "Linked $@"

# C compilation (compiled as C++ because z8lua headers require C++ <cstdint>)
$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CXX) $(CFLAGS) -x c++ -c -o $@ $<

# C++ compilation
$(BUILD_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# Objective-C++ compilation
$(BUILD_DIR)/%.o: %.mm
	@mkdir -p $(dir $@)
	$(OBJCXX) $(OBJCXXFLAGS) -c -o $@ $<

# Install to the Xcode build products directory (next to other core plugins)
install: $(PLUGIN_BUNDLE)
	@rm -rf "$(OE_BUILD_DIR)/$(PLUGIN_BUNDLE)"
	@cp -R $(PLUGIN_BUNDLE) "$(OE_BUILD_DIR)/$(PLUGIN_BUNDLE)"
	@echo "Installed to $(OE_BUILD_DIR)/$(PLUGIN_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR) $(PLUGIN_BUNDLE)
