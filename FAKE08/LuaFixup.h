#pragma once
#include <stddef.h>
#include <stdint.h>

struct lua_State;

#ifdef __cplusplus
extern "C" {
#endif

// Collect offsets within the arena where C function/data pointers are stored.
size_t lua_collect_ptr_offsets(lua_State *L, uint32_t *out, size_t max_out);

// Apply delta to the pointer at each recorded offset.
void lua_apply_offset_fixup(const uint32_t *offsets, size_t count, ptrdiff_t delta);

#ifdef __cplusplus
}
#endif
