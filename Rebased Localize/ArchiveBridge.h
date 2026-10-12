#ifndef ArchiveBridge_h
#define ArchiveBridge_h
#include <zlib.h>
static inline int rl_inflate_init(z_stream *stream) {
    return inflateInit2(stream, -MAX_WBITS);
}
static inline int rl_deflate_init(z_stream *stream) {
    return deflateInit2(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
}
#endif
