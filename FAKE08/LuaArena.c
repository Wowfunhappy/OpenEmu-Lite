#include "LuaArena.h"
#include <malloc/malloc.h>

// See LuaArena.h. The previous implementation was a hand-rolled free-list
// allocator in a fixed-address mmap; its O(n) list walks (thousands of free
// blocks, no backward coalescing) made every Lua GC cycle take hundreds of
// milliseconds in allocation-heavy carts. A malloc zone gives us the system
// allocator's performance plus wholesale teardown via malloc_destroy_zone.

static malloc_zone_t *lua_zone = NULL;

void *lua_arena_init(void) {
    if (lua_zone != NULL) {
        // Fresh Lua state: throw away everything the old one allocated.
        malloc_destroy_zone(lua_zone);
        lua_zone = NULL;
    }
    lua_zone = malloc_create_zone(0, 0);
    if (lua_zone != NULL) {
        malloc_set_zone_name(lua_zone, "FAKE08 Lua");
    }
    return lua_zone;
}

void lua_arena_destroy(void) {
    if (lua_zone != NULL) {
        malloc_destroy_zone(lua_zone);
        lua_zone = NULL;
    }
}

// Lua-compatible allocator: behaves like realloc.
// ptr=NULL, nsize>0 → malloc
// ptr!=NULL, nsize=0 → free
// ptr!=NULL, nsize>0 → realloc
void *lua_arena_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    malloc_zone_t *zone = (malloc_zone_t *)ud;
    (void)osize;

    if (nsize == 0) {
        if (ptr != NULL) {
            malloc_zone_free(zone, ptr);
        }
        return NULL;
    }
    if (ptr == NULL) {
        return malloc_zone_malloc(zone, nsize);
    }
    return malloc_zone_realloc(zone, ptr, nsize);
}

void *lua_arena_base(void) {
    return lua_zone;
}
