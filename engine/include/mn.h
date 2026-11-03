/*
 * mn.h - MAC_NTFS engine: a small, stable C API over libntfs-3g.
 *
 * Everything outside engine/ (the CLI now, the FSKit module later) talks to
 * NTFS only through this header, so libntfs-3g types never leak out.
 *
 * Items are addressed by inode number, matching how FSKit identifies items.
 * mn_resolve() turns a path into an inode for path-based callers like the CLI.
 *
 * Names are UTF-8. Not thread-safe: callers serialize access per volume.
 */
#ifndef MN_H
#define MN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MN_OK = 0,
    MN_ERR_NOT_NTFS,        /* no NTFS boot sector */
    MN_ERR_CORRUPT,         /* metadata inconsistent; run chkdsk on Windows */
    MN_ERR_HIBERNATED,      /* Windows hibernated / Fast Startup: unsafe to write */
    MN_ERR_UNCLEAN,         /* journal not empty (unsafe removal): unsafe to write */
    MN_ERR_BUSY,            /* device in use */
    MN_ERR_NO_PRIVILEGE,    /* cannot open device */
    MN_ERR_NOT_FOUND,
    MN_ERR_NOT_DIR,
    MN_ERR_IS_DIR,
    MN_ERR_READ_ONLY,       /* write attempted on a read-only volume */
    MN_ERR_EXISTS,
    MN_ERR_NOT_EMPTY,
    MN_ERR_NO_SPACE,
    MN_ERR_PERMISSION,      /* NTFS metadata, encrypted file, ... */
    MN_ERR_BAD_NAME,        /* not a valid Windows file name */
    MN_ERR_UNSUPPORTED,
    MN_ERR_INVALID,
    MN_ERR_IO,
    MN_ERR_NOMEM,
    MN_ERR_UNKNOWN,
} mn_err;

const char *mn_strerror(mn_err err);

/* ---- Volumes ---- */

typedef struct mn_volume mn_volume;

enum {
    MN_OPEN_READ_ONLY  = 0,
    MN_OPEN_READ_WRITE = 1 << 0,  /* refused with HIBERNATED/UNCLEAN when unsafe */
};

mn_err mn_volume_open(const char *device, unsigned flags, mn_volume **out);
mn_err mn_volume_close(mn_volume *vol);

typedef struct {
    char     label[128];        /* UTF-8, may be empty */
    uint8_t  major_ver, minor_ver;
    uint32_t cluster_size;
    uint64_t total_bytes;
    uint64_t free_bytes;
    bool     read_only;         /* as opened */
    /* Safety state, checked regardless of how the volume was opened. */
    bool     dirty;             /* $Volume dirty flag set (chkdsk scheduled) */
    bool     hibernated;        /* hiberfil.sys active, or Fast Startup metadata cache */
    bool     unclean_journal;   /* $LogFile has unreplayed transactions */
} mn_volume_info;

mn_err mn_volume_get_info(mn_volume *vol, mn_volume_info *info);

/* ---- Items ---- */

#define MN_ROOT_INODE 5         /* NTFS FILE_root */

typedef enum {
    MN_TYPE_FILE,
    MN_TYPE_DIR,
    MN_TYPE_SYMLINK,            /* symlinks and other reparse points */
    MN_TYPE_OTHER,
} mn_type;

/* Windows file attribute bits (subset), reported in mn_attr.win_attrs. */
enum {
    MN_WIN_READONLY   = 0x0001,
    MN_WIN_HIDDEN     = 0x0002,
    MN_WIN_SYSTEM     = 0x0004,
    MN_WIN_ARCHIVE    = 0x0020,
    MN_WIN_SPARSE     = 0x0200,
    MN_WIN_REPARSE    = 0x0400,
    MN_WIN_COMPRESSED = 0x0800,
    MN_WIN_ENCRYPTED  = 0x4000,
};

typedef struct {
    uint64_t inode;
    mn_type  type;
    uint64_t size;              /* logical size of unnamed $DATA */
    uint64_t alloc_size;        /* bytes allocated on disk */
    uint32_t win_attrs;
    uint32_t nlink;
    struct timespec birth_time; /* creation */
    struct timespec mod_time;   /* data change */
    struct timespec change_time;/* MFT record change */
    struct timespec access_time;
} mn_attr;

mn_err mn_stat(mn_volume *vol, uint64_t inode, mn_attr *attr);

/* Look up one name in a directory. */
mn_err mn_lookup(mn_volume *vol, uint64_t dir_inode, const char *name, uint64_t *inode_out);

/* Resolve an absolute path ("/a/b") to an inode. */
mn_err mn_resolve(mn_volume *vol, const char *path, uint64_t *inode_out);

typedef struct {
    const char *name;           /* UTF-8, valid only during the callback */
    uint64_t    inode;
    mn_type     type;
} mn_dirent;

/* Return non-zero from the callback to stop early. Skips "." / ".." and NTFS metadata files. */
typedef int (*mn_readdir_cb)(void *ctx, const mn_dirent *ent);
mn_err mn_readdir(mn_volume *vol, uint64_t dir_inode, mn_readdir_cb cb, void *ctx);

/* Read up to len bytes from a file's unnamed $DATA. *nread < len only at EOF. */
mn_err mn_read(mn_volume *vol, uint64_t inode, uint64_t offset,
               void *buf, size_t len, size_t *nread);

/* ---- Writing (volume must be opened MN_OPEN_READ_WRITE) ----
 *
 * New names must be valid on Windows: no \ / : * ? " < > |, no trailing
 * dot or space, no reserved device names (CON, NUL, COM1, ...).
 */

/* type must be MN_TYPE_FILE or MN_TYPE_DIR. */
mn_err mn_create(mn_volume *vol, uint64_t dir_inode, const char *name,
                 mn_type type, uint64_t *inode_out);

/* Writes all of len bytes or fails. Extends the file as needed. */
mn_err mn_write(mn_volume *vol, uint64_t inode, uint64_t offset,
                const void *buf, size_t len);

mn_err mn_truncate(mn_volume *vol, uint64_t inode, uint64_t size);

/* Remove a file, or an empty directory. */
mn_err mn_remove(mn_volume *vol, uint64_t dir_inode, const char *name);

/*
 * Move/rename. An existing destination is replaced if it is a file, or an
 * empty directory when the source is a directory.
 */
mn_err mn_rename(mn_volume *vol, uint64_t src_dir, const char *src_name,
                 uint64_t dst_dir, const char *dst_name);

/* Any NULL time is left unchanged. */
mn_err mn_set_times(mn_volume *vol, uint64_t inode, const struct timespec *birth,
                    const struct timespec *mod, const struct timespec *access);

/* Set the MN_WIN_READONLY/HIDDEN/SYSTEM/ARCHIVE bits named in mask to those in attrs. */
mn_err mn_set_win_attrs(mn_volume *vol, uint64_t inode, uint32_t mask, uint32_t attrs);

/* Flush to the device. */
mn_err mn_sync(mn_volume *vol);

#ifdef __cplusplus
}
#endif

#endif /* MN_H */
