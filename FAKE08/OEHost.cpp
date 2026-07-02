/*
 OpenEmu Host implementation for fake-08.
 Mirrors the libretro host pattern - provides stub implementations
 for platform functions since OpenEmu handles video/audio/input directly.
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>

#include <fstream>
#include <iostream>
#include <deque>
#include <mutex>
using namespace std;

#include "host.h"
#include "hostVmShared.h"
#include "nibblehelpers.h"

static uint8_t stubCurrKDown;
static uint8_t stubCurrKHeld;
static bool stubCurrKBdown = false;
static std::string stubCurrKBkey = "";
static int16_t stubMouseX;
static int16_t stubMouseY;
static uint8_t stubMouseBtns;

// Keys arrive on the input (DO) thread; scanInput runs on the emulation thread.
static std::deque<std::string> stubKeyQueue;
static std::mutex stubKeyQueueMutex;

void oeSetInputState(uint8_t kDown, uint8_t kHeld, int16_t mouseX, int16_t mouseY, uint8_t mouseBtns) {
    // Accumulate "just pressed" flags so presses that land on a frame where
    // the cart doesn't call _update_buttons() (e.g. the yield frame of a
    // 30fps cart) survive until the cart actually reads them.
    stubCurrKDown |= kDown;
    stubCurrKHeld = kHeld;
    stubMouseX = mouseX;
    stubMouseY = mouseY;
    stubMouseBtns = mouseBtns;
}

void oePushKeyboardKey(const char* key) {
    std::lock_guard<std::mutex> lock(stubKeyQueueMutex);
    if (stubKeyQueue.size() < 64) {
        stubKeyQueue.push_back(key);
    }
}

Host::Host(int windowWidth, int windowHeight) { }

void Host::oneTimeSetup(Audio* audio) { }

void Host::oneTimeCleanup() { }

void Host::setTargetFps(int targetFps) { }

void Host::changeStretch() { }

void Host::forceStretch(StretchOption newStretch) { }

InputState_t Host::scanInput() {
    // Surface one queued devkit-keyboard key per scan. The cart consumes it
    // via stat(31) (Input::getKey clears the down flag), so each key is seen
    // exactly once even if typing outpaces the cart's update rate.
    stubCurrKBdown = false;
    stubCurrKBkey = "";
    {
        std::lock_guard<std::mutex> lock(stubKeyQueueMutex);
        if (!stubKeyQueue.empty()) {
            stubCurrKBdown = true;
            stubCurrKBkey = stubKeyQueue.front();
            stubKeyQueue.pop_front();
        }
    }
    InputState_t state = {stubCurrKDown, stubCurrKHeld, stubMouseX, stubMouseY, stubMouseBtns, stubCurrKBdown, stubCurrKBkey};
    // Clear "just pressed" after reading so each press is only seen once.
    stubCurrKDown = 0;
    return state;
}

bool Host::shouldQuit() {
    return false;
}

void Host::waitForTargetFps() { }

void Host::drawFrame(uint8_t* picoFb, uint8_t* screenPaletteMap, uint8_t screenMode) { }

bool Host::shouldFillAudioBuff() {
    return false;
}

void* Host::getAudioBufferPointer() {
    return nullptr;
}

size_t Host::getAudioBufferSize() {
    return 0;
}

void Host::playFilledAudioBuffer() { }

bool Host::shouldRunMainLoop() {
    if (shouldQuit()) {
        return false;
    }
    return true;
}

vector<string> Host::listcarts() {
    vector<string> carts;
    return carts;
}

std::string Host::customBiosLua() {
    return "";
}

std::string Host::getCartDirectory() {
    return _cartDirectory;
}

std::vector<std::string> Host::listdirs() {
    std::vector<std::string> dirs;
    return dirs;
}

void Host::overrideLogFilePrefix(const char* newPrefix) {
    _logFilePrefix = newPrefix;

    struct stat st = {0};
    string cartdatadir = _logFilePrefix + "cdata";
    if (stat(cartdatadir.c_str(), &st) == -1) {
        mkdir(cartdatadir.c_str(), 0777);
    }
}
