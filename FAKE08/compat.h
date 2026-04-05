// Compatibility header for building fake-08 with old Apple clang (LLVM 3.5)
// Fixes missing declarations when compiling C files as C++

#pragma once

#include <cstdlib>  // strtol
#include <stdint.h>

// Old libc++ std::abs is ambiguous for int64_t
