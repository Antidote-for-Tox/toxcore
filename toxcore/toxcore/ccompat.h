/*
 * C language compatibility macros for varying compiler support.
 */
#ifndef CCOMPAT_H
#define CCOMPAT_H

// Variable length arrays.
// VLA(type, name, size) allocates a variable length array with automatic
// storage duration. VLA_SIZE(name) evaluates to the runtime size of that array
// in bytes.
//
// If C99 VLAs are not available, an emulation using alloca (stack allocation
// "function") is used. Note the semantic difference: alloca'd memory does not
// get freed at the end of the declaration's scope. Do not use VLA() in loops or
// you may run out of stack space.
#if !defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
// C99 VLAs.
#define VLA(type, name, size) type name[size]
#define SIZEOF_VLA sizeof
#else

// Emulation using alloca.
#ifdef _WIN32
#include <malloc.h>
#elif defined(__FreeBSD__)
#include <stdlib.h>
#if !defined(alloca) && defined(__GNUC__)
#define alloca __builtin_alloca
#endif
#else
#include <alloca.h>
#endif

#define VLA(type, name, size)                           \
  const size_t name##_size = (size) * sizeof(type);     \
  type *const name = (type *)alloca(name##_size)
#define SIZEOF_VLA(name) name##_size

#endif

#ifndef __cplusplus
#define nullptr NULL
#endif

#ifdef __GNUC__
#define GNU_PRINTF __attribute__((__format__(__printf__, 6, 7)))
#else
#define GNU_PRINTF
#endif

#endif /* CCOMPAT_H */
