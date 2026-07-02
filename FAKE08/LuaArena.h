#pragma once

#include <stddef.h>

// Lua allocator backed by a private macOS malloc zone.
//
// Historically this was a fixed-address mmap arena so save states could dump
// the raw Lua heap. Save states are now eris object-graph serializations and
// don't care where Lua memory lives, but the zone keeps the arena's one
// remaining useful property: Vm::HardReset can abandon a (possibly corrupt)
// Lua state and reclaim ALL of its memory in one shot by destroying the zone,
// without lua_close() walking GC lists that may contain garbage pointers.

#ifdef __cplusplus
extern "C" {
#endif

// Create the zone, destroying the previous one (and everything in it) if
// this is a re-init for a fresh Lua state. Returns the opaque allocator
// userdata to pass to lua_newstate, or NULL on failure.
void *lua_arena_init(void);

// Destroy the zone and all memory allocated from it.
void lua_arena_destroy(void);

// Lua-compatible allocator function (matches lua_Alloc signature).
// ud is the pointer returned by lua_arena_init.
void *lua_arena_alloc(void *ud, void *ptr, size_t osize, size_t nsize);

// The current zone (opaque), or NULL if not initialized. Used as a
// "Lua memory exists" sanity check by the save-state code.
void *lua_arena_base(void);

#ifdef __cplusplus
}
#endif
