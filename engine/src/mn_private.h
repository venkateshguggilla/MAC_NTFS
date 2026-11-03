/* Internal interfaces shared between engine source files. */
#ifndef MN_PRIVATE_H
#define MN_PRIVATE_H

#include "mn.h"

struct ntfs_device;

/* Wrap an mn_io in a libntfs-3g device. The io is copied. */
struct ntfs_device *mn_io_device_alloc(const mn_io *io, const char *name);

/* Free what mn_io_device_alloc() stored in dev->d_private, calling io->release. */
void mn_io_device_release(void *d_private);

/* File-descriptor backend for images and /dev nodes. Returns 0 or an errno value. */
int mn_io_open_fd(const char *path, bool rw, mn_io *io);

#endif /* MN_PRIVATE_H */
