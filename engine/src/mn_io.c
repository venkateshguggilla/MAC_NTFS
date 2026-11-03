/*
 * mn_io.c - libntfs-3g device operations on top of an mn_io backend.
 *
 * libntfs-3g issues reads and writes of any size at any offset (boot
 * sectors, 1 KiB MFT records, partial clusters). Raw disks and FSKit's
 * FSBlockDeviceResource only accept whole blocks, so this layer widens every
 * request to block boundaries, using read-modify-write for partial blocks.
 *
 * Also provides the file-descriptor backend used for images and /dev nodes.
 */
#include "mn_private.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/device.h>

typedef struct {
    mn_io io;
    s64 pos;                    /* for the seek/read/write ops */
} io_dev;

static io_dev *dev_io(struct ntfs_device *dev)
{
    return dev->d_private;
}

static uint64_t round_down(uint64_t v, uint64_t bs) { return v & ~(bs - 1); }
static uint64_t round_up(uint64_t v, uint64_t bs)   { return (v + bs - 1) & ~(bs - 1); }

static int io_open(struct ntfs_device *dev, int flags)
{
    if (NDevOpen(dev)) {
        errno = EBUSY;
        return -1;
    }
    if ((flags & O_ACCMODE) == O_RDONLY)
        NDevSetReadOnly(dev);
    else if (!dev_io(dev)->io.write) {
        errno = EROFS;
        return -1;
    }
    NDevSetOpen(dev);
    return 0;
}

static int io_close(struct ntfs_device *dev)
{
    if (NDevDirty(dev) && dev_io(dev)->io.sync)
        dev_io(dev)->io.sync(dev_io(dev)->io.ctx);
    NDevClearOpen(dev);
    return 0;
}

static s64 io_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset)
{
    const mn_io *io = &dev_io(dev)->io;
    if (count < 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }
    if ((uint64_t)offset >= io->size || count == 0)
        return 0;
    if ((uint64_t)(offset + count) > io->size)
        count = (s64)(io->size - (uint64_t)offset);

    uint64_t bs = io->block_size ? io->block_size : 1;
    uint64_t start = round_down((uint64_t)offset, bs);
    uint64_t end = round_up((uint64_t)(offset + count), bs);
    size_t done = 0;
    int err;

    if (start == (uint64_t)offset && end == (uint64_t)(offset + count)) {
        err = io->read(io->ctx, buf, start, (size_t)count, &done);
    } else {
        char *bounce = malloc(end - start);
        if (!bounce) {
            errno = ENOMEM;
            return -1;
        }
        err = io->read(io->ctx, bounce, start, end - start, &done);
        uint64_t skip = (uint64_t)offset - start;
        done = done > skip ? done - skip : 0;
        if (done > (size_t)count)
            done = (size_t)count;
        memcpy(buf, bounce + skip, done);
        free(bounce);
    }
    if (err) {
        errno = err;
        return -1;
    }
    return (s64)done;
}

/* Read one whole block at a block-aligned offset; past the end reads as zeros. */
static int read_block(const mn_io *io, char *blk, uint64_t offset, uint64_t bs)
{
    size_t done = 0;
    memset(blk, 0, bs);
    if (offset >= io->size)
        return 0;
    return io->read(io->ctx, blk, offset, bs, &done);
}

static s64 io_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset)
{
    const mn_io *io = &dev_io(dev)->io;
    if (NDevReadOnly(dev)) {
        errno = EROFS;
        return -1;
    }
    if (count < 0 || offset < 0) {
        errno = EINVAL;
        return -1;
    }
    if ((uint64_t)(offset + count) > io->size) {
        errno = ENOSPC;
        return -1;
    }
    if (count == 0)
        return 0;
    NDevSetDirty(dev);

    uint64_t bs = io->block_size ? io->block_size : 1;
    uint64_t off = (uint64_t)offset, len = (uint64_t)count;
    uint64_t start = round_down(off, bs);
    uint64_t end = round_up(off + len, bs);
    int err;

    if (start == off && end == off + len) {
        err = io->write(io->ctx, buf, off, len);
    } else {
        /* Fill in the untouched parts of the first and last blocks from disk. */
        char *bounce = malloc(end - start);
        if (!bounce) {
            errno = ENOMEM;
            return -1;
        }
        err = 0;
        if (start != off)
            err = read_block(io, bounce, start, bs);
        if (!err && end != off + len && (end - bs != start || start == off))
            err = read_block(io, bounce + (end - bs - start), end - bs, bs);
        if (!err) {
            memcpy(bounce + (off - start), buf, len);
            err = io->write(io->ctx, bounce, start, end - start);
        }
        free(bounce);
    }
    if (err) {
        errno = err;
        return -1;
    }
    return count;
}

static s64 io_seek(struct ntfs_device *dev, s64 offset, int whence)
{
    io_dev *d = dev_io(dev);
    switch (whence) {
    case SEEK_SET: d->pos = offset; break;
    case SEEK_CUR: d->pos += offset; break;
    case SEEK_END: d->pos = (s64)d->io.size + offset; break;
    default:
        errno = EINVAL;
        return -1;
    }
    return d->pos;
}

static s64 io_read(struct ntfs_device *dev, void *buf, s64 count)
{
    s64 n = io_pread(dev, buf, count, dev_io(dev)->pos);
    if (n > 0)
        dev_io(dev)->pos += n;
    return n;
}

static s64 io_write(struct ntfs_device *dev, const void *buf, s64 count)
{
    s64 n = io_pwrite(dev, buf, count, dev_io(dev)->pos);
    if (n > 0)
        dev_io(dev)->pos += n;
    return n;
}

static int io_sync(struct ntfs_device *dev)
{
    const mn_io *io = &dev_io(dev)->io;
    if (NDevReadOnly(dev) || !io->sync)
        return 0;
    int err = io->sync(io->ctx);
    if (err) {
        errno = err;
        return -1;
    }
    NDevClearDirty(dev);
    return 0;
}

static int io_stat(struct ntfs_device *dev, struct stat *st)
{
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFBLK;
    st->st_size = (off_t)dev_io(dev)->io.size;
    return 0;
}

static int io_ioctl(struct ntfs_device *dev, unsigned long request, void *argp)
{
    const mn_io *io = &dev_io(dev)->io;
    switch (request) {
    case DKIOCGETBLOCKSIZE:
        *(uint32_t *)argp = io->block_size > 1 ? io->block_size : 512;
        return 0;
    case DKIOCGETBLOCKCOUNT:
        *(uint64_t *)argp = io->size / (io->block_size > 1 ? io->block_size : 512);
        return 0;
    default:
        errno = EOPNOTSUPP;
        return -1;
    }
}

static struct ntfs_device_operations io_ops = {
    .open = io_open,
    .close = io_close,
    .seek = io_seek,
    .read = io_read,
    .write = io_write,
    .pread = io_pread,
    .pwrite = io_pwrite,
    .sync = io_sync,
    .stat = io_stat,
    .ioctl = io_ioctl,
};

struct ntfs_device *mn_io_device_alloc(const mn_io *io, const char *name)
{
    if (!io->read || !io->size ||
        (io->block_size & (io->block_size - 1))) {
        errno = EINVAL;
        return NULL;
    }
    io_dev *d = calloc(1, sizeof(*d));
    if (!d) {
        errno = ENOMEM;
        return NULL;
    }
    d->io = *io;
    struct ntfs_device *dev = ntfs_device_alloc(name, 0, &io_ops, d);
    if (!dev) {
        free(d);
        return NULL;
    }
    return dev;
}

void mn_io_device_release(void *d_private)
{
    io_dev *d = d_private;
    if (!d)
        return;
    if (d->io.release)
        d->io.release(d->io.ctx);
    free(d);
}

/* ---- File descriptor backend (images, /dev nodes) ---- */

typedef struct {
    int fd;
    uint32_t block_size;
} fd_ctx;

static int fd_read(void *p, void *buf, uint64_t offset, size_t len, size_t *done)
{
    fd_ctx *c = p;
    *done = 0;
    if ((offset | len) & (c->block_size - 1))
        return EINVAL;          /* alignment bug in the layer above */
    while (*done < len) {
        ssize_t n = pread(c->fd, (char *)buf + *done, len - *done, (off_t)(offset + *done));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return errno;
        }
        if (n == 0)
            break;
        *done += (size_t)n;
    }
    return 0;
}

static int fd_write(void *p, const void *buf, uint64_t offset, size_t len)
{
    fd_ctx *c = p;
    if ((offset | len) & (c->block_size - 1))
        return EINVAL;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(c->fd, (const char *)buf + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return errno;
        }
        done += (size_t)n;
    }
    return 0;
}

static int fd_sync(void *p)
{
    fd_ctx *c = p;
    /* F_FULLFSYNC asks the drive to flush its cache too; fall back where unsupported. */
    if (fcntl(c->fd, F_FULLFSYNC) == 0 || fsync(c->fd) == 0)
        return 0;
    return errno;
}

static void fd_release(void *p)
{
    fd_ctx *c = p;
    close(c->fd);
    free(c);
}

int mn_io_open_fd(const char *path, bool rw, mn_io *io)
{
    int fd = open(path, rw ? O_RDWR : O_RDONLY);
    if (fd < 0)
        return errno;

    struct stat st;
    if (fstat(fd, &st) < 0) {
        int e = errno;
        close(fd);
        return e;
    }

    uint32_t bs = 1;
    uint64_t size;
    if (S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) {
        uint64_t count;
        if (ioctl(fd, DKIOCGETBLOCKSIZE, &bs) < 0 ||
            ioctl(fd, DKIOCGETBLOCKCOUNT, &count) < 0) {
            int e = errno;
            close(fd);
            return e;
        }
        size = count * bs;
    } else {
        size = (uint64_t)st.st_size;
        /* Tests set MN_ALIGN to make images behave like 4K-sector disks. */
        const char *align = getenv("MN_ALIGN");
        if (align)
            bs = (uint32_t)strtoul(align, NULL, 10);
    }
    if (!bs || (bs & (bs - 1))) {
        close(fd);
        return EINVAL;
    }

    fd_ctx *c = malloc(sizeof(*c));
    if (!c) {
        close(fd);
        return ENOMEM;
    }
    c->fd = fd;
    c->block_size = bs;
    *io = (mn_io){
        .ctx = c,
        .block_size = bs,
        .size = size,
        .read = fd_read,
        .write = rw ? fd_write : NULL,
        .sync = fd_sync,
        .release = fd_release,
    };
    return 0;
}
