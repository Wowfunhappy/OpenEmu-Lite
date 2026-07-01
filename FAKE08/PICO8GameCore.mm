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

// Lua hook: periodically checks if a reset was requested AND enforces a
// per-frame instruction budget so that infinite loops (e.g. `repeat until
// false` in carts whose load() fails) cannot hang the emulator.
static volatile BOOL *s_resetFlag = NULL;
static int s_instrCount = 0;
static const int kMaxInstrsPerFrame = 5000000; // ~5M instructions ≈ generous budget

static void luaResetHook(lua_State *L, lua_Debug *ar) {
    if (s_resetFlag && *s_resetFlag) {
        luaL_error(L, "reset requested");
    }
    s_instrCount += 10000; // hook fires every 10k instructions
    if (s_instrCount > kMaxInstrsPerFrame) {
        luaL_error(L, "frame budget exceeded (infinite loop?)");
    }
}

// SIGSEGV/SIGBUS recovery for corrupt save states.
- (void)executeFrame
{
    // Process deferred reset on the emulation thread
    if (_resetQueued) {
        _resetQueued = NO;
        _vm->HardReset(_romPath);
    }

    // Install reset hook so corrupt states / infinite loops can't freeze permanently.
    // The hook checks the reset flag every 10k Lua instructions and enforces a
    // per-frame instruction budget.
    s_resetFlag = &_resetQueued;
    s_instrCount = 0;
    lua_State *L = _vm->getLuaState();
    if (L) lua_sethook(L, luaResetHook, LUA_MASKCOUNT, 10000);

    // Feed input state to the host before stepping.
    oeSetInputState(_kDown, _kHeld, 0, 0, 0);

    bool stepOK = _vm->Step();

    // Remove hook after normal execution (avoid overhead)
    L = _vm->getLuaState();
    if (L) lua_sethook(L, NULL, 0, 0);

    if (!stepOK) {
        lua_getglobal(L, "__z8_last_error");
        const char *luaErr = lua_isstring(L, -1) ? lua_tostring(L, -1) : "(unknown)";
        NSLog(@"PICO-8: cart error — %s", luaErr);
        lua_pop(L, 1);
    }

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
    uint8_t drawMode = _memory->drawState.drawMode;

    // drawMode (poke 0x5f2c) selects which sub-region of the 128x128 framebuffer
    // is active.  Modes 1-3 use a half/quarter region that must be stretched to
    // fill the full display; modes 129-135 apply mirror/rotation.
    int srcW = PicoScreenWidth;
    int srcH = PicoScreenHeight;
    bool flipX = false, flipY = false, rotate = false;

    switch (drawMode) {
        case 1:   srcW = 64; break;
        case 2:   srcH = 64; break;
        case 3:   srcW = 64; srcH = 64; break;
        case 129: flipX = true; break;
        case 130: flipY = true; break;
        case 131: flipX = true; flipY = true; break;
        case 133: rotate = true; break;                    // 90°
        case 134: flipX = true; flipY = true; break;      // 180° same as double-flip
        case 135: rotate = true; flipX = true; flipY = true; break; // 270°
        default:  break;
    }

    for (int y = 0; y < PicoScreenHeight; y++) {
        for (int x = 0; x < PicoScreenWidth; x++) {
            int sx = x * srcW / PicoScreenWidth;
            int sy = y * srcH / PicoScreenHeight;

            if (flipX) sx = srcW - 1 - sx;
            if (flipY) sy = srcH - 1 - sy;
            if (rotate) {
                int tmp = sx;
                sx = sy;
                sy = srcW - 1 - tmp;
            }

            uint8_t colorIdx = screenPaletteMap[getPixelNibble(sx, sy, picoFb)] & 0x8f;
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
    return OEIntSizeMake(PicoScreenWidth, PicoScreenHeight);
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

    // Serialize the full Lua state with eris. Unlike a raw heap image, an eris
    // blob is a portable object graph: C functions are mapped to stable indices
    // via the permanents table, so restoring needs NO pointer fixup and works
    // across ASLR and core rebuilds. The pico-8 RAM and audio-engine state are
    // plain C structs, saved raw alongside the blob.
    lua_getglobal(L, "eris");
    if (lua_type(L, -1) != LUA_TTABLE) {
        NSLog(@"PICO-8: eris library not available, cannot save state");
        lua_pop(L, 1);
        if (block) block(NO, nil);
        return;
    }
    lua_getfield(L, -1, "persist_all");
    if (lua_type(L, -1) != LUA_TFUNCTION) {
        lua_pop(L, 2);
        if (block) block(NO, nil);
        return;
    }
    // Stop the GC across persist for the same reason as unpersist (and to avoid
    // a collection walking the graph while we serialize it). The resulting blob
    // string stays referenced on the Lua stack, so restarting the GC before we
    // read it is safe.
    lua_gc(L, LUA_GCSTOP, 0);
    int persistRc = lua_pcall(L, 0, 1, 0);
    lua_gc(L, LUA_GCRESTART, 0);
    if (persistRc != 0) {
        NSLog(@"PICO-8: eris persist failed: %s", lua_tostring(L, -1));
        lua_pop(L, 2);
        if (block) block(NO, nil);
        return;
    }
    size_t blobLen = 0;
    const char *blob = lua_tolstring(L, -1, &blobLen);
    if (!blob || blobLen == 0) {
        lua_pop(L, 2);
        if (block) block(NO, nil);
        return;
    }

    // Build uncompressed payload: [blobLen][eris blob][PicoRam][audioState]
    size_t payloadSize = sizeof(size_t) + blobLen + sizeof(PicoRam) + sizeof(audioState_t);
    char *payload = (char *)malloc(payloadSize);
    size_t off = 0;
    memcpy(payload + off, &blobLen, sizeof(size_t)); off += sizeof(size_t);
    memcpy(payload + off, blob, blobLen); off += blobLen;
    memcpy(payload + off, memory->data, sizeof(PicoRam)); off += sizeof(PicoRam);
    memcpy(payload + off, _audio->getAudioState(), sizeof(audioState_t));
    lua_pop(L, 2); // eris blob string + eris table

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

    // Header (version 15 = eris) + uncompressed size + compressed payload.
    NSMutableData *stateData = [NSMutableData data];
    char header[4] = {'f', '8', 0, 15}; // version 15 (eris)
    [stateData appendBytes:header length:4];
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
    if (version != 15) {
        NSLog(@"PICO-8: Save state version %d != 15, ignoring", version);
        return;
    }

    size_t offset = 4;
    if (total < offset + sizeof(size_t)) {
        NSLog(@"PICO-8: Save state truncated, ignoring");
        return;
    }
    size_t payloadSize;
    memcpy(&payloadSize, data + offset, sizeof(size_t));
    offset += sizeof(size_t);
    size_t compSize = total - offset;

    if (payloadSize < sizeof(size_t) + sizeof(PicoRam) + sizeof(audioState_t) ||
        payloadSize > 64u * 1024 * 1024) {
        NSLog(@"PICO-8: Save state payload size %zu implausible, ignoring", payloadSize);
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

    // Parse payload: [blobLen][eris blob][PicoRam][audioState]
    size_t poff = 0;
    size_t blobLen;
    memcpy(&blobLen, payload + poff, sizeof(size_t)); poff += sizeof(size_t);
    if (blobLen == 0 ||
        poff + blobLen + sizeof(PicoRam) + sizeof(audioState_t) != payloadSize) {
        NSLog(@"PICO-8: Save state payload malformed, ignoring");
        free(payload);
        return;
    }
    const char *blob = payload + poff; poff += blobLen;
    const char *picoRamData = payload + poff; poff += sizeof(PicoRam);
    const char *audioData = payload + poff;

    // Deserialize the Lua state with eris. The cart has already been loaded on
    // this frame (Step ran first), so the permanents table is built and _G holds
    // fresh C functions; eris.restore_all rebuilds the persisted object graph and
    // copies it back into _G — no pointer fixup, no arena-base dependency.
    lua_State *L = _vm->getLuaState();
    lua_getglobal(L, "eris");
    if (lua_type(L, -1) != LUA_TTABLE) {
        NSLog(@"PICO-8: eris library not available, cannot load state");
        lua_pop(L, 1);
        free(payload);
        return;
    }
    lua_getfield(L, -1, "restore_all");
    if (lua_type(L, -1) != LUA_TFUNCTION) {
        lua_pop(L, 2);
        free(payload);
        return;
    }
    lua_pushlstring(L, blob, blobLen);
    // Stop the GC across unpersist: eris builds the object graph incrementally,
    // and a collection triggered by an allocation mid-build would mark a
    // half-constructed object and crash (luaC_forcestep -> propagatemark).
    lua_gc(L, LUA_GCSTOP, 0);
    int restoreRc = lua_pcall(L, 1, 0, 0);
    lua_gc(L, LUA_GCRESTART, 0);
    if (restoreRc != 0) {
        NSLog(@"PICO-8: eris restore failed: %s", lua_tostring(L, -1));
        lua_pop(L, 2); // error message + eris table
        free(payload);
        return;
    }
    lua_pop(L, 1); // eris table
    NSLog(@"PICO-8: eris restore OK (%zu byte blob)", blobLen);

    // Restore pico-8 RAM and audio-engine state (plain C structs).
    memcpy(_memory->data, picoRamData, sizeof(PicoRam));
    memcpy(_audio->getAudioState(), audioData, sizeof(audioState_t));

    free(payload);

    // Clear the pause menu flag so it can't get out of sync with the
    // Pause Emulation menu item.
    _vm->clearPauseMenu();
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
