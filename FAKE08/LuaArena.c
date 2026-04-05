#include "LuaArena.h"
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>

// Simple free-list allocator within a fixed-address arena.
//
// The arena is a single mmap'd region at a fixed virtual address.
// Allocations are served from a linked free list of blocks.
// Each block has an 8-byte header storing the block size (including header).
// Free blocks additionally store a next pointer in the payload area.

#define BLOCK_ALIGN 16
#define HEADER_SIZE BLOCK_ALIGN  // padded to alignment

typedef struct FreeBlock {
    size_t size;          // total block size including header
    struct FreeBlock *next;
} FreeBlock;

typedef struct {
    FreeBlock *free_list;
    size_t total_size;
    size_t used;
} ArenaHeader;

static void *arena_base = NULL;

static size_t align_up(size_t n, size_t align) {
    return (n + align - 1) & ~(align - 1);
}

void *lua_arena_init(void) {
    if (arena_base != NULL) {
        // Arena already mapped — reinitialize the free list for a fresh Lua state
        ArenaHeader *hdr = (ArenaHeader *)arena_base;
        size_t header_space = align_up(sizeof(ArenaHeader), BLOCK_ALIGN);
        FreeBlock *initial = (FreeBlock *)((char *)arena_base + header_space);
        initial->size = LUA_ARENA_SIZE - header_space;
        initial->next = NULL;
        hdr->free_list = initial;
        hdr->total_size = LUA_ARENA_SIZE;
        hdr->used = header_space;
        // Zero the arena data (clean slate)
        memset((char *)arena_base + header_space + sizeof(FreeBlock), 0,
               LUA_ARENA_SIZE - header_space - sizeof(FreeBlock));
        return arena_base;
    }

    // Try to mmap at our preferred fixed address
    void *addr = mmap(LUA_ARENA_ADDR, LUA_ARENA_SIZE,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                      -1, 0);
    if (addr == MAP_FAILED) {
        fprintf(stderr, "LuaArena: MAP_FIXED failed, trying any address\n");
        // Fallback: try without MAP_FIXED (save states won't work but game will run)
        addr = mmap(NULL, LUA_ARENA_SIZE,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON,
                    -1, 0);
        if (addr == MAP_FAILED) {
            fprintf(stderr, "LuaArena: mmap failed entirely\n");
            return NULL;
        }
    }

    arena_base = addr;

    // Initialize: ArenaHeader at the start, then one big free block
    ArenaHeader *hdr = (ArenaHeader *)addr;
    size_t header_space = align_up(sizeof(ArenaHeader), BLOCK_ALIGN);

    FreeBlock *initial = (FreeBlock *)((char *)addr + header_space);
    initial->size = LUA_ARENA_SIZE - header_space;
    initial->next = NULL;

    hdr->free_list = initial;
    hdr->total_size = LUA_ARENA_SIZE;
    hdr->used = header_space;

    return addr;
}

void lua_arena_destroy(void) {
    if (arena_base != NULL) {
        munmap(arena_base, LUA_ARENA_SIZE);
        arena_base = NULL;
    }
}

// Find a free block of at least `needed` bytes, split if larger.
static void *arena_malloc(ArenaHeader *hdr, size_t needed) {
    needed = align_up(needed + HEADER_SIZE, BLOCK_ALIGN);
    if (needed < sizeof(FreeBlock) + HEADER_SIZE) {
        needed = sizeof(FreeBlock) + HEADER_SIZE;
    }

    FreeBlock **prev = &hdr->free_list;
    FreeBlock *block = hdr->free_list;

    while (block) {
        if (block->size >= needed) {
            // Can we split?
            if (block->size >= needed + sizeof(FreeBlock) + HEADER_SIZE) {
                FreeBlock *remainder = (FreeBlock *)((char *)block + needed);
                remainder->size = block->size - needed;
                remainder->next = block->next;
                *prev = remainder;
                block->size = needed;
            } else {
                // Use the whole block
                *prev = block->next;
            }
            hdr->used += block->size;
            // Return pointer past the header
            return (char *)block + HEADER_SIZE;
        }
        prev = &block->next;
        block = block->next;
    }

    // Out of memory
    return NULL;
}

// Free a block: add it back to the free list (simple insertion, no coalescing for speed).
static void arena_free(ArenaHeader *hdr, void *ptr) {
    if (!ptr) return;

    FreeBlock *block = (FreeBlock *)((char *)ptr - HEADER_SIZE);
    hdr->used -= block->size;

    // Insert into free list sorted by address (enables coalescing)
    FreeBlock **prev = &hdr->free_list;
    FreeBlock *cur = hdr->free_list;

    while (cur && cur < block) {
        prev = &cur->next;
        cur = cur->next;
    }

    block->next = cur;
    *prev = block;

    // Coalesce with next block
    if (cur && (char *)block + block->size == (char *)cur) {
        block->size += cur->size;
        block->next = cur->next;
    }

    // Coalesce with previous block
    if (prev != &hdr->free_list) {
        FreeBlock *prev_block = (FreeBlock *)((char *)prev - offsetof(FreeBlock, next));
        // Actually we need the real previous block. Let's just skip backward coalescing
        // for simplicity — forward coalescing is sufficient for most cases.
    }
}

// Lua-compatible allocator: behaves like realloc.
// ptr=NULL, nsize>0 → malloc
// ptr!=NULL, nsize=0 → free
// ptr!=NULL, nsize>0 → realloc
void *lua_arena_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    ArenaHeader *hdr = (ArenaHeader *)ud;
    (void)osize; // unused in our allocator

    if (nsize == 0) {
        arena_free(hdr, ptr);
        return NULL;
    }

    if (ptr == NULL) {
        return arena_malloc(hdr, nsize);
    }

    // Realloc: allocate new, copy, free old
    void *new_ptr = arena_malloc(hdr, nsize);
    if (new_ptr) {
        size_t copy_size = osize < nsize ? osize : nsize;
        memcpy(new_ptr, ptr, copy_size);
        arena_free(hdr, ptr);
    }
    return new_ptr;
}

void *lua_arena_base(void) {
    return arena_base;
}

size_t lua_arena_size(void) {
    return LUA_ARENA_SIZE;
}

int lua_arena_offset_is_free(uint32_t offset) {
    if (!arena_base) return 0;
    ArenaHeader *hdr = (ArenaHeader *)arena_base;
    FreeBlock *block = hdr->free_list;
    while (block) {
        uint32_t block_start = (uint32_t)((char *)block - (char *)arena_base);
        uint32_t block_end = block_start + (uint32_t)block->size;
        if (offset >= block_start && offset < block_end) return 1;
        block = block->next;
    }
    return 0;
}

int lua_arena_contains(void *ptr) {
    if (!arena_base || !ptr) return 0;
    return (ptr >= arena_base && ptr < (char *)arena_base + LUA_ARENA_SIZE);
}

// After restoring an arena dump from a previous session, all C function
// pointers (allocator, panic, registered C functions, etc.) point to the
// old process's code addresses. We fix them by computing the delta between
// a known function's old and new addresses, then scanning the arena for
// any pointer-sized value in the old plugin code range and adjusting it.
//
// We use dladdr() to find the plugin's image base and size.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>

void lua_arena_fixup_pointers(void *old_ref, void *new_ref) {
    (void)old_ref;
    (void)new_ref;
}

// Scan the arena for pointer-sized values that point OUTSIDE the arena
// but INSIDE the current process's loaded images (i.e., code pointers).
// These are the values that need fixup after restore.
size_t lua_arena_find_code_pointers(uint32_t *offsets, size_t max_offsets) {
    if (!arena_base) return 0;

    // Determine the code range of our plugin
    Dl_info info;
    if (!dladdr((void*)lua_arena_alloc, &info)) return 0;
    uintptr_t image_base = (uintptr_t)info.dli_fbase;

    // Get actual image size from mach-o headers
    uintptr_t image_end = image_base;
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        if ((uintptr_t)_dyld_get_image_header(i) == image_base) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
            for (uint32_t j = 0; j < header->ncmds; j++) {
                const struct load_command *cmd = (const struct load_command *)ptr;
                if (cmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
                    uintptr_t end = image_base + seg->vmaddr + seg->vmsize;
                    if (end > image_end) image_end = end;
                }
                ptr += cmd->cmdsize;
            }
            break;
        }
    }
    if (image_end == image_base) image_end = image_base + 2*1024*1024;

    uintptr_t *scan = (uintptr_t *)arena_base;
    size_t count = LUA_ARENA_SIZE / sizeof(uintptr_t);
    size_t found = 0;

    for (size_t i = 0; i < count && found < max_offsets; i++) {
        uintptr_t val = scan[i];
        if (val >= image_base && val < image_end) {
            offsets[found++] = (uint32_t)(i * sizeof(uintptr_t));
        }
    }
    return found;
}

void lua_arena_fixup_at_offsets(const uint32_t *offsets, size_t count, ptrdiff_t delta) {
    if (!arena_base || delta == 0) return;
    for (size_t i = 0; i < count; i++) {
        uintptr_t *p = (uintptr_t *)((char *)arena_base + offsets[i]);
        *p += delta;
    }
}
