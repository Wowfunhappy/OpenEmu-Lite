/*
 Copyright (c) 2024, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "PICO8GameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OEPICO8SystemResponderClient.h"
#import <OpenGL/gl.h>

#include "vm.h"
#include "PicoRam.h"
#include "Audio.h"
#include "host.h"
#include "hostVmShared.h"
#include "nibblehelpers.h"
#include "filehelpers.h"
#include "OEHostHelpers.h"
#include "LuaArena.h"
#include "LuaFixup.h"
#include <zlib.h>

#define SAMPLERATE 22050
#define SAMPLESPERFRAME (SAMPLERATE / 60)

static const int PicoScreenWidth = 128;
static const int PicoScreenHeight = 128;

@interface PICO8GameCore () <OEPICO8SystemResponderClient>
{
    Vm *_vm;
    PicoRam *_memory;
    Audio *_audio;
    Host *_host;

    uint32_t *_videoBuffer;
    int16_t *_audioBuffer;
    int16_t *_monoBuffer;

    uint32_t _rgbaColors[144];

    uint8_t _kHeld;
    uint8_t _kDown;

    size_t _frameCount;
    NSString *_pendingSaveStatePath;
    volatile BOOL _resetQueued;
    std::string _romPath;  // original cart path, stable across resets
}
@end

@implementation PICO8GameCore

- (id)init
{
    if ((self = [super init]))
    {
        _videoBuffer = (uint32_t *)calloc(PicoScreenWidth * PicoScreenHeight, sizeof(uint32_t));
        _audioBuffer = (int16_t *)calloc(SAMPLESPERFRAME * 2, sizeof(int16_t));
        _monoBuffer = (int16_t *)calloc(SAMPLESPERFRAME, sizeof(int16_t));
        _kHeld = 0;
        _kDown = 0;
        _frameCount = 0;
    }
    return self;
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _host = new Host();

    NSString *savePath = [self batterySavesDirectoryPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:savePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    std::string saveDirStr = [savePath UTF8String];
    if (saveDirStr.back() != '/') {
        saveDirStr += "/";
    }
    _host->overrideLogFilePrefix(saveDirStr.c_str());

    _memory = new PicoRam();
    _audio = new Audio(_memory);
    _vm = new Vm(_host, _memory, nullptr, nullptr, _audio);

    _host->setUpPaletteColors();
    Color *paletteColors = _host->GetPaletteColors();
    _host->oneTimeSetup(_audio);

    // Build RGBA color lookup table
    for (int i = 0; i < 144; i++) {
        _rgbaColors[i] = (paletteColors[i].Alpha << 24) |
                          (paletteColors[i].Blue << 16) |
                          (paletteColors[i].Green << 8) |
                          paletteColors[i].Red;
    }

    _vm->SetCartList(_host->listcarts());

    // Determine cart directory
    std::string fullPath = [path UTF8String];
    auto containingDir = getDirectory(fullPath);
    if (containingDir.length() > 0) {
        _host->setCartDirectory(containingDir);
    }

    // Queue the cart load by filename path.
    // (QueueCartChange with raw data only stores the pointer, not a copy,
    // so the data must remain valid until Step() processes it. Using the
    // filename path avoids this lifetime issue entirely.)
    _romPath = fullPath;
    _vm->QueueCartChange(fullPath);

    return YES;
}

// Lua hook: periodically checks if a reset was requested.
// This allows "Reset Console" to break out of infinite loops caused by
// corrupt save states or buggy carts.
static volatile BOOL *s_resetFlag = NULL;
static void luaResetHook(lua_State *L, lua_Debug *ar) {
    if (s_resetFlag && *s_resetFlag) {
        luaL_error(L, "reset requested");
    }
}

// SIGSEGV/SIGBUS recovery for corrupt save states.
// If Step() dereferences corrupt Lua data, we catch the signal and
// recover via longjmp instead of crashing.
#include <signal.h>
#include <setjmp.h>
static sigjmp_buf s_crashRecovery;
static volatile sig_atomic_t s_crashProtectionActive = 0;
static struct sigaction s_oldSIGSEGV, s_oldSIGBUS;

static void crashHandler(int sig) {
    if (s_crashProtectionActive) {
        s_crashProtectionActive = 0;
        siglongjmp(s_crashRecovery, sig);
    }
    // Not our crash — forward to previous handler
    struct sigaction *old = (sig == SIGSEGV) ? &s_oldSIGSEGV : &s_oldSIGBUS;
    if (old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN) {
        old->sa_handler(sig);
    } else {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

- (void)executeFrame
{
    // Process deferred reset on the emulation thread
    if (_resetQueued) {
        _resetQueued = NO;
        _vm->HardReset(_romPath);
    }

    // Install reset hook so corrupt states can't freeze permanently
    s_resetFlag = &_resetQueued;
    lua_State *L = _vm->getLuaState();
    if (L) lua_sethook(L, luaResetHook, LUA_MASKCOUNT, 10000);

    // Feed input state to the host before stepping.
    oeSetInputState(_kDown, _kHeld, 0, 0, 0);

    // Protect Step() against SIGSEGV/SIGBUS from corrupt Lua state.
    // If a crash occurs, recover by doing a hard reset.
    struct sigaction sa = {};
    sa.sa_handler = crashHandler;
    sa.sa_flags = 0;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &s_oldSIGSEGV);
    sigaction(SIGBUS, &sa, &s_oldSIGBUS);

    s_crashProtectionActive = 1;
    int crashed = sigsetjmp(s_crashRecovery, 1);
    if (crashed) {
        // Crashed inside Step() — recover with a hard reset
        NSLog(@"PICO-8: Caught signal %d in Step(), performing hard reset", crashed);
        _vm->HardReset(_romPath);
        // Restore default signal handlers
        sigaction(SIGSEGV, &s_oldSIGSEGV, NULL);
        sigaction(SIGBUS, &s_oldSIGBUS, NULL);
    } else {
        _vm->Step();
        s_crashProtectionActive = 0;
        sigaction(SIGSEGV, &s_oldSIGSEGV, NULL);
        sigaction(SIGBUS, &s_oldSIGBUS, NULL);
    }

    // Remove hook after normal execution
    L = _vm->getLuaState();
    if (L) lua_sethook(L, NULL, 0, 0);

    // Check for pending save state load (deferred from loadStateFromFileAtPath)
    // This runs on the emulation thread, after Step() has loaded the cart on the first frame.
    if (_pendingSaveStatePath) {
        NSString *path = _pendingSaveStatePath;
        _pendingSaveStatePath = nil;
        [self _doLoadState:path];
        // Skip the rest of this frame — the next frame will render the restored state
        _frameCount++;
        return;
    }

    _kDown = 0; // clear "just pressed" flags after each frame

    // Fill audio - FillMonoAudioBuffer writes int16_t mono samples,
    // then we interleave to stereo for OpenEmu's ring buffer
    _audio->FillMonoAudioBuffer(_monoBuffer, 0, SAMPLESPERFRAME);
    for (int i = 0; i < SAMPLESPERFRAME; i++) {
        _audioBuffer[i * 2]     = _monoBuffer[i];
        _audioBuffer[i * 2 + 1] = _monoBuffer[i];
    }
    [[self ringBufferAtIndex:0] write:_audioBuffer maxLength:SAMPLESPERFRAME * 2 * sizeof(int16_t)];

    // Render framebuffer
    uint8_t *picoFb = _vm->GetPicoInteralFb();
    uint8_t *screenPaletteMap = _vm->GetScreenPaletteMap();

    for (int y = 0; y < PicoScreenHeight; y++) {
        for (int x = 0; x < PicoScreenWidth; x++) {
            uint8_t colorIdx = screenPaletteMap[getPixelNibble(x, y, picoFb)] & 0x8f;
            _videoBuffer[y * PicoScreenWidth + x] = _rgbaColors[colorIdx];
        }
    }




    _frameCount++;
}

- (void)resetEmulation
{
    // Called from a non-game-core thread; defer to executeFrame so all Vm
    // access stays on the emulation thread.
    _resetQueued = YES;
}

- (void)setupEmulation
{
}

- (void)stopEmulation
{
    // Don't destroy the Vm here — the autosave may still be accessing the
    // Lua state on another thread. Just close the cart and let dealloc clean up.
    if (_vm) {
        _vm->CloseCart();
        if (_host) _host->oneTimeCleanup();
    }

    [super stopEmulation];
}

- (void)dealloc
{
    if (_vm) {
        delete _vm;
        _vm = nullptr;
    }
    if (_host) {
        delete _host;
        _host = nullptr;
    }
    _audio = nullptr;
    _memory = nullptr;
    free(_videoBuffer);
    free(_audioBuffer);
    free(_monoBuffer);
    // Don't destroy the arena — it's a fixed mmap that gets reinitialized on next use
}

- (NSTimeInterval)frameInterval
{
    return 60.0;
}

#pragma mark - Video

- (const void *)videoBuffer
{
    return _videoBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, PicoScreenWidth, PicoScreenHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(PicoScreenWidth, PicoScreenHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(1, 1);
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return SAMPLERATE;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // Capture locals to avoid race with stopEmulation on another thread
    Vm *vm = _vm;
    PicoRam *memory = _memory;
    void *arena = lua_arena_base();

    if (!vm || !memory || !arena) {
        if (block) block(NO, nil);
        return;
    }

    lua_State *L = vm->getLuaState();
    if (!L) {
        if (block) block(NO, nil);
        return;
    }

    // Force full GC collection to ensure consistent state
    lua_gc(L, LUA_GCCOLLECT, 0);

    size_t arenaSize = lua_arena_size();
    ptrdiff_t luaStateOffset = (char *)L - (char *)arena;

    // Build uncompressed payload: arena + PicoRam + luaStateOffset + audioState
    size_t payloadSize = arenaSize + sizeof(PicoRam) + sizeof(ptrdiff_t) + sizeof(audioState_t);
    char *payload = (char *)malloc(payloadSize);
    size_t off = 0;
    memcpy(payload + off, arena, arenaSize); off += arenaSize;
    memcpy(payload + off, memory->data, sizeof(PicoRam)); off += sizeof(PicoRam);
    memcpy(payload + off, &luaStateOffset, sizeof(ptrdiff_t)); off += sizeof(ptrdiff_t);
    memcpy(payload + off, _audio->getAudioState(), sizeof(audioState_t));

    // Compress with zlib
    uLongf compSize = compressBound(payloadSize);
    char *compressed = (char *)malloc(compSize);
    int zret = compress2((Bytef *)compressed, &compSize, (const Bytef *)payload, payloadSize, 1);
    free(payload);

    if (zret != Z_OK) {
        free(compressed);
        if (block) block(NO, nil);
        return;
    }

    // Re-check lua state (might have been destroyed during GC or by quit)
    if (!vm->getLuaState()) {
        free(compressed);
        if (block) block(NO, nil);
        return;
    }

    // Collect exact offsets of all C function/data pointers in the arena
    uint32_t *ptrOffsets = (uint32_t *)malloc(65536 * sizeof(uint32_t));
    size_t numOffsets = lua_collect_ptr_offsets(vm->getLuaState(), ptrOffsets, 65536);

    NSMutableData *stateData = [NSMutableData data];
    char header[4] = {'f', '8', 0, 11}; // version 11 = arena + offset-based fixup
    [stateData appendBytes:header length:4];
    void *base = arena;
    [stateData appendBytes:&base length:sizeof(void *)];
    void *ref = (void *)lua_arena_alloc;
    [stateData appendBytes:&ref length:sizeof(void *)];
    // Pointer offset table
    [stateData appendBytes:&numOffsets length:sizeof(size_t)];
    if (numOffsets > 0)
        [stateData appendBytes:ptrOffsets length:numOffsets * sizeof(uint32_t)];
    free(ptrOffsets);
    // Compressed payload
    [stateData appendBytes:&payloadSize length:sizeof(size_t)];
    [stateData appendBytes:compressed length:compSize];
    free(compressed);

    BOOL success = [stateData writeToFile:fileName atomically:YES];
    if (block) block(success, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    // Defer the actual load to the next executeFrame so it happens
    // BEFORE Step() processes the cart, not after.
    _pendingSaveStatePath = [fileName copy];
    if (block) block(YES, nil);
}

- (void)_doLoadState:(NSString *)fileName
{
    if (!_vm || !_memory || !_audio || !lua_arena_base()) {
        return;
    }

    NSData *stateData = [NSData dataWithContentsOfFile:fileName];
    if (!stateData || [stateData length] < 8) {
        NSLog(@"PICO-8: Save state too small or unreadable, ignoring");
        return;
    }

    const char *data = (const char *)[stateData bytes];
    size_t total = [stateData length];

    if (data[0] != 'f' || data[1] != '8') {
        NSLog(@"PICO-8: Save state has bad magic, ignoring");
        return;
    }

    uint8_t version = data[3];
    if (version != 11) {
        NSLog(@"PICO-8: Save state version %d != 11, ignoring", version);
        return;
    }

    size_t offset = 4;

    void *savedBase;
    memcpy(&savedBase, data + offset, sizeof(void *));
    offset += sizeof(void *);

    void *savedRef;
    memcpy(&savedRef, data + offset, sizeof(void *));
    offset += sizeof(void *);

    if (savedBase != lua_arena_base()) {
        NSLog(@"PICO-8: Save state arena base mismatch, ignoring");
        return;
    }

    // Read pointer offset table
    size_t numOffsets;
    memcpy(&numOffsets, data + offset, sizeof(size_t));
    offset += sizeof(size_t);
    const uint32_t *ptrOffsets = NULL;
    if (numOffsets > 0 && numOffsets < 65536) {
        ptrOffsets = (const uint32_t *)(data + offset);
        offset += numOffsets * sizeof(uint32_t);
    }

    size_t payloadSize;
    memcpy(&payloadSize, data + offset, sizeof(size_t));
    offset += sizeof(size_t);
    size_t compSize = total - offset;
    size_t expectedSize = lua_arena_size() + sizeof(PicoRam) + sizeof(ptrdiff_t) + sizeof(audioState_t);

    if (payloadSize != expectedSize) {
        NSLog(@"PICO-8: Save state payload size %zu != expected %zu, ignoring", payloadSize, expectedSize);
        return;
    }

    char *payload = (char *)malloc(payloadSize);
    uLongf destLen = payloadSize;
    int zret = uncompress((Bytef *)payload, &destLen, (const Bytef *)(data + offset), compSize);
    if (zret != Z_OK || destLen != payloadSize) {
        NSLog(@"PICO-8: Save state decompression failed (zret=%d), ignoring", zret);
        free(payload);
        return;
    }

    size_t arenaSize = lua_arena_size();

    // Validate lua_State offset before touching the arena
    ptrdiff_t luaStateOffset;
    memcpy(&luaStateOffset, payload + arenaSize + sizeof(PicoRam), sizeof(ptrdiff_t));
    if (luaStateOffset < 0 || (size_t)luaStateOffset >= arenaSize) {
        NSLog(@"PICO-8: Save state lua_State offset %td out of arena bounds, ignoring", luaStateOffset);
        free(payload);
        return;
    }

    // Stop GC before overwriting the arena
    lua_gc(_vm->getLuaState(), LUA_GCSTOP, 0);

    // Restore arena
    memcpy(lua_arena_base(), payload, arenaSize);

    // Restore PicoRam
    memcpy(_memory->data, payload + arenaSize, sizeof(PicoRam));

    // Compute restored lua_State pointer
    lua_State *restoredL = (lua_State *)((char *)lua_arena_base() + luaStateOffset);

    // Apply pointer fixup
    ptrdiff_t delta = (char *)lua_arena_alloc - (char *)savedRef;
    if (delta != 0 && ptrOffsets && numOffsets > 0) {
        // Apply precise offset-based fixup (only at struct-walk-identified locations)
        lua_apply_offset_fixup(ptrOffsets, numOffsets, delta);

        // Also fix dummynode references (single value, safe to brute scan)
        extern const void *luaT_getdummynode(void);
        uintptr_t newDummy = (uintptr_t)luaT_getdummynode();
        uintptr_t oldDummy = newDummy - delta;
        uintptr_t *scan = (uintptr_t *)lua_arena_base();
        size_t count = lua_arena_size() / sizeof(uintptr_t);
        for (size_t i = 0; i < count; i++) {
            if (scan[i] == oldDummy) scan[i] = newDummy;
        }
    }
    _vm->setLuaState(restoredL, 0);

    // Restore audio state
    memcpy(_audio->getAudioState(), payload + arenaSize + sizeof(PicoRam) + sizeof(ptrdiff_t), sizeof(audioState_t));

    free(payload);

    // Restart GC
    lua_gc(_vm->getLuaState(), LUA_GCRESTART, 0);

    // Dismiss the in-game pause menu if it was active when the state was saved,
    // so it can't get out of sync with the Pause Emulation menu item.
    if (_vm->IsPaused()) {
        _kDown |= P8_KEY_PAUSE;
        _kHeld |= P8_KEY_PAUSE;
    }
}

#pragma mark - Pause

- (void)setPauseEmulation:(BOOL)flag
{
    // Toggle PICO-8's in-game pause menu instead of freezing emulation.
    // The VM must keep running so the pause menu can render.
    [self didPushPICO8Button:OEPICO8ButtonPause];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self didReleasePICO8Button:OEPICO8ButtonPause];
    });
}

#pragma mark - Input

- (oneway void)didPushPICO8Button:(OEPICO8Button)button
{
    uint8_t mask = 0;
    switch (button) {
        case OEPICO8ButtonLeft:  mask = P8_KEY_LEFT;  break;
        case OEPICO8ButtonRight: mask = P8_KEY_RIGHT; break;
        case OEPICO8ButtonUp:    mask = P8_KEY_UP;    break;
        case OEPICO8ButtonDown:  mask = P8_KEY_DOWN;  break;
        case OEPICO8ButtonO:     mask = P8_KEY_O;     break;
        case OEPICO8ButtonX:     mask = P8_KEY_X;     break;
        case OEPICO8ButtonPause: mask = P8_KEY_PAUSE; break;
        default: return;
    }

    if (!(_kHeld & mask)) {
        _kDown |= mask;
    }
    _kHeld |= mask;
}

- (oneway void)didReleasePICO8Button:(OEPICO8Button)button
{
    uint8_t mask = 0;
    switch (button) {
        case OEPICO8ButtonLeft:  mask = P8_KEY_LEFT;  break;
        case OEPICO8ButtonRight: mask = P8_KEY_RIGHT; break;
        case OEPICO8ButtonUp:    mask = P8_KEY_UP;    break;
        case OEPICO8ButtonDown:  mask = P8_KEY_DOWN;  break;
        case OEPICO8ButtonO:     mask = P8_KEY_O;     break;
        case OEPICO8ButtonX:     mask = P8_KEY_X;     break;
        case OEPICO8ButtonPause: mask = P8_KEY_PAUSE; break;
        default: return;
    }

    _kHeld &= ~mask;
}

@end
