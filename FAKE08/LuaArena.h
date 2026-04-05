#pragma once

#include <stddef.h>
#include <stdint.h>

// Fixed-address arena allocator for Lua.
// All Lua allocations go into a single contiguous memory region mapped
// at a fixed virtual address. This allows save states by simply dumping
// the entire region to disk and restoring it at the same address.

// Arena size: 4MB (PICO-8 Lua limit is 2MB, plus overhead for allocator metadata)
#define LUA_ARENA_SIZE (4 * 1024 * 1024)

// Fixed virtual address for the arena. Chosen to be in an unused region
// of the 64-bit address space, far from typical heap/stack/library regions.
#define LUA_ARENA_ADDR ((void *)0x400000000ULL)

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the arena: mmap a fixed-address region and set up the free list.
// Returns the arena base pointer, or NULL on failure.
void *lua_arena_init(void);

// Destroy the arena: munmap the region.
void lua_arena_destroy(void);

// Lua-compatible allocator function (matches lua_Alloc signature).
// ud is the arena base pointer returned by lua_arena_init.
void *lua_arena_alloc(void *ud, void *ptr, size_t osize, size_t nsize);

// Get the arena base address (for save/load).
void *lua_arena_base(void);

// Get the arena size.
size_t lua_arena_size(void);

// Check if a pointer is within the arena.
int lua_arena_contains(void *ptr);

// Fixup: after restoring an arena from a different process, all C function
// pointers inside it are wrong (ASLR). Call this to adjust them.
void lua_arena_fixup_pointers(void *old_ref, void *new_ref);

// Build a list of offsets within the arena that contain code pointers.
// Returns the count. Writes offsets to the provided buffer.
size_t lua_arena_find_code_pointers(uint32_t *offsets, size_t max_offsets);

// Apply fixup only to the specified offsets.
void lua_arena_fixup_at_offsets(const uint32_t *offsets, size_t count, ptrdiff_t delta);

// Check if an offset falls within a free block (should not be scanned/fixed)
int lua_arena_offset_is_free(uint32_t offset);

#ifdef __cplusplus
}
#endif
