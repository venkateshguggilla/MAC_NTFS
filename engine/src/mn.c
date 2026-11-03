/*
 * mn.c - MAC_NTFS engine implementation over libntfs-3g.
 */
#include "mn_private.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/cache.h>

#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>

struct mn_volume {
    ntfs_volume *nv;
    void *io_private;           /* backend owned by mn_io.c */
    bool read_only;
};

const char *mn_strerror(mn_err err)
{
    switch (err) {
    case MN_OK:               return "success";
    case MN_ERR_NOT_NTFS:     return "not an NTFS volume";
    case MN_ERR_CORRUPT:      return "NTFS metadata is inconsistent (run chkdsk on Windows)";
    case MN_ERR_HIBERNATED:   return "Windows is hibernated or used Fast Startup; "
                                     "shut Windows down fully before writing";
    case MN_ERR_UNCLEAN:      return "volume was not safely removed; "
                                     "reconnect it to Windows and eject it cleanly";
    case MN_ERR_BUSY:         return "device is busy";
    case MN_ERR_NO_PRIVILEGE: return "permission denied opening device";
    case MN_ERR_NOT_FOUND:    return "no such file or directory";
    case MN_ERR_NOT_DIR:      return "not a directory";
    case MN_ERR_IS_DIR:       return "is a directory";
    case MN_ERR_READ_ONLY:    return "volume is read-only";
    case MN_ERR_EXISTS:       return "file exists";
    case MN_ERR_NOT_EMPTY:    return "directory not empty";
    case MN_ERR_NO_SPACE:     return "no space left on volume";
    case MN_ERR_PERMISSION:   return "operation not permitted";
    case MN_ERR_BAD_NAME:     return "name is not valid on Windows";
    case MN_ERR_UNSUPPORTED:  return "operation not supported";
    case MN_ERR_INVALID:      return "invalid argument";
    case MN_ERR_IO:           return "I/O error";
    case MN_ERR_NOMEM:        return "out of memory";
    case MN_ERR_UNKNOWN:      break;
    }
    return "unknown error";
}

static mn_err map_errno(int e)
{
    switch (e) {
    case 0:          return MN_OK;
    case ENOENT:     return MN_ERR_NOT_FOUND;
    case ENOTDIR:    return MN_ERR_NOT_DIR;
    case EISDIR:     return MN_ERR_IS_DIR;
    case EROFS:      return MN_ERR_READ_ONLY;
    case EINVAL:     return MN_ERR_INVALID;
    case EIO:        return MN_ERR_IO;
    case ENOMEM:     return MN_ERR_NOMEM;
    case EBUSY:      return MN_ERR_BUSY;
    case EEXIST:     return MN_ERR_EXISTS;
    case ENOTEMPTY:  return MN_ERR_NOT_EMPTY;
    case ENOSPC:     return MN_ERR_NO_SPACE;
    case EPERM:
    case EACCES:     return MN_ERR_PERMISSION;
    case ENAMETOOLONG: return MN_ERR_BAD_NAME;
    case EOPNOTSUPP: return MN_ERR_UNSUPPORTED;
    default:         return MN_ERR_UNKNOWN;
    }
}

/* ntfs_mount() reports why it refused a volume through errno; see ntfs_volume_error(). */
static mn_err map_mount_errno(int e)
{
    switch (e) {
    case EINVAL:     return MN_ERR_NOT_NTFS;
    case EIO:        return MN_ERR_CORRUPT;
    case EPERM:      return MN_ERR_HIBERNATED;
    case EOPNOTSUPP: return MN_ERR_UNCLEAN;
    case EACCES:     return MN_ERR_NO_PRIVILEGE;
    default:         return map_errno(e);
    }
}

/* ---- Volumes ---- */

static void setup_logging(void)
{
    static bool done;
    if (done)
        return;
    done = true;
    /* libntfs-3g logs to stderr by default; the engine stays silent unless debugging. */
    if (getenv("MN_DEBUG"))
        ntfs_log_set_handler(ntfs_log_handler_stderr);
    else
        ntfs_log_set_handler(ntfs_log_handler_null);
}

mn_err mn_volume_open_io(const mn_io *io, const char *name, unsigned flags, mn_volume **out)
{
    *out = NULL;
    setup_logging();

    bool rw = flags & MN_OPEN_READ_WRITE;
    mn_volume *vol = NULL;
    struct ntfs_device *dev = NULL;
    mn_err err = MN_OK;

    if (rw && !io->write)
        err = MN_ERR_READ_ONLY;
    else if (!(vol = calloc(1, sizeof(*vol))))
        err = MN_ERR_NOMEM;
    else if (!(dev = mn_io_device_alloc(io, name)))
        err = map_errno(errno);
    if (err) {
        if (io->release)
            io->release(io->ctx);
        free(vol);
        return err;
    }
    void *priv = dev->d_private;

    /*
     * Read-write never passes NTFS_MNT_RECOVER, NTFS_MNT_IGNORE_HIBERFILE or
     * NTFS_MNT_MAY_RDONLY: hibernated or unclean volumes fail outright.
     */
    ntfs_volume *nv = ntfs_device_mount(dev, rw ? NTFS_MNT_NONE : NTFS_MNT_RDONLY);
    if (!nv) {
        err = map_mount_errno(errno);
        ntfs_device_free(dev);
        mn_io_device_release(priv);
        free(vol);
        return err;
    }
    ntfs_create_lru_caches(nv);   /* as ntfs_mount() does */
    /* Scan the cluster and MFT bitmaps once; libntfs-3g keeps the counts current. */
    ntfs_volume_get_free_space(nv);

    /* Show hidden files, hide NTFS metadata ($MFT, ...). */
    ntfs_set_shown_files(nv, FALSE, TRUE, FALSE);

    vol->nv = nv;
    vol->io_private = priv;
    vol->read_only = !rw;
    *out = vol;
    return MN_OK;
}

mn_err mn_volume_open(const char *device, unsigned flags, mn_volume **out)
{
    *out = NULL;
    mn_io io;
    int e = mn_io_open_fd(device, flags & MN_OPEN_READ_WRITE, &io);
    if (e)
        return e == EACCES || e == EPERM ? MN_ERR_NO_PRIVILEGE : map_errno(e);
    mn_err err = mn_volume_open_io(&io, device, flags, out);
    /* On failure the device layer has already released io; nothing else to free. */
    return err;
}

mn_err mn_volume_close(mn_volume *vol)
{
    if (!vol)
        return MN_OK;
    /* ntfs_umount() closes and frees the ntfs_device, but not our backend. */
    mn_err err = ntfs_umount(vol->nv, FALSE) ? map_errno(errno) : MN_OK;
    mn_io_device_release(vol->io_private);
    free(vol);
    return err;
}

void mn_volume_get_space(mn_volume *vol, mn_volume_space *space)
{
    ntfs_volume *nv = vol->nv;
    space->cluster_size = nv->cluster_size;
    space->total_clusters = (uint64_t)nv->nr_clusters;
    space->free_clusters = nv->free_clusters > 0 ? (uint64_t)nv->free_clusters : 0;
    space->total_inodes = (uint64_t)(nv->mft_na->initialized_size >> nv->mft_record_size_bits);
    space->free_inodes = nv->free_mft_records > 0 ? (uint64_t)nv->free_mft_records : 0;
}

const char *mn_volume_label(mn_volume *vol)
{
    return vol->nv->vol_name ? vol->nv->vol_name : "";
}

uint64_t mn_volume_serial(mn_volume *vol)
{
    NTFS_BOOT_SECTOR bs;
    struct ntfs_device *dev = vol->nv->dev;
    if (dev->d_ops->pread(dev, &bs, sizeof(bs), 0) != sizeof(bs))
        return 0;
    return le64_to_cpu(bs.volume_serial_number);
}

/* Mirrors libntfs-3g's private ntfs_volume_check_logfile(). */
static void check_logfile(ntfs_volume *nv, bool *unclean, bool *cached)
{
    *unclean = *cached = false;

    ntfs_inode *ni = ntfs_inode_open(nv, FILE_LogFile);
    if (!ni) {
        *unclean = true;
        return;
    }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        *unclean = true;
    } else {
        RESTART_PAGE_HEADER *rp = NULL;
        if (!ntfs_check_logfile(na, &rp) || !ntfs_is_logfile_clean(na, rp))
            *unclean = true;
        /* Restart page v2.0: Windows kept metadata cached for Fast Startup. */
        if (rp && rp->major_ver == const_cpu_to_le16(2) &&
            rp->minor_ver == const_cpu_to_le16(0))
            *cached = true;
        free(rp);
        ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
}

mn_err mn_volume_get_info(mn_volume *vol, mn_volume_info *info)
{
    ntfs_volume *nv = vol->nv;
    memset(info, 0, sizeof(*info));

    if (nv->vol_name)
        strlcpy(info->label, nv->vol_name, sizeof(info->label));
    info->major_ver = nv->major_ver;
    info->minor_ver = nv->minor_ver;
    info->cluster_size = nv->cluster_size;
    info->total_bytes = (uint64_t)nv->nr_clusters * nv->cluster_size;
    if (ntfs_volume_get_free_space(nv) == 0 && nv->free_clusters >= 0)
        info->free_bytes = (uint64_t)nv->free_clusters * nv->cluster_size;
    info->read_only = vol->read_only;

    info->dirty = (nv->flags & VOLUME_IS_DIRTY) != 0;
    bool cached;
    check_logfile(nv, &info->unclean_journal, &cached);
    info->hibernated = cached ||
        (ntfs_volume_check_hiberfile(nv, 0) < 0 && errno == EPERM);
    return MN_OK;
}

/* ---- Items ---- */

static mn_type type_of(ntfs_inode *ni)
{
    if (ni->flags & FILE_ATTR_REPARSE_POINT)
        return MN_TYPE_SYMLINK;
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY)
        return MN_TYPE_DIR;
    return MN_TYPE_FILE;
}

static mn_type type_of_dt(unsigned dt)
{
    switch (dt) {
    case NTFS_DT_DIR:     return MN_TYPE_DIR;
    case NTFS_DT_REG:     return MN_TYPE_FILE;
    case NTFS_DT_LNK:
    case NTFS_DT_REPARSE: return MN_TYPE_SYMLINK;
    default:              return MN_TYPE_OTHER;
    }
}

static mn_err open_inode(mn_volume *vol, uint64_t inode, ntfs_inode **out)
{
    *out = ntfs_inode_open(vol->nv, (MFT_REF)inode);
    return *out ? MN_OK : map_errno(errno);
}

mn_err mn_stat(mn_volume *vol, uint64_t inode, mn_attr *attr)
{
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;

    memset(attr, 0, sizeof(*attr));
    attr->inode = ni->mft_no;
    attr->type = type_of(ni);
    attr->win_attrs = le32_to_cpu(ni->flags);
    attr->nlink = attr->type == MN_TYPE_DIR ? 1 : le16_to_cpu(ni->mrec->link_count);
    attr->birth_time = ntfs2timespec(ni->creation_time);
    attr->mod_time = ntfs2timespec(ni->last_data_change_time);
    attr->change_time = ntfs2timespec(ni->last_mft_change_time);
    attr->access_time = ntfs2timespec(ni->last_access_time);

    if (attr->type == MN_TYPE_FILE) {
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (!na) {
            err = map_errno(errno);
        } else {
            attr->size = na->data_size;
            attr->alloc_size = (na->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_SPARSE))
                ? na->compressed_size : na->allocated_size;
            ntfs_attr_close(na);
        }
    }
    ntfs_inode_close(ni);
    return err;
}

/*
 * Look a name up the way Windows does: case-insensitive, preferring an exact
 * match. libntfs-3g's ignore-case mode would also lowercase every name that
 * readdir returns, so it is enabled only for the duration of the lookup.
 */
static u64 lookup_ci(ntfs_inode *dir, const ntfschar *uname, int ulen)
{
    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref != (u64)-1 || errno != ENOENT)
        return mref;
    ntfs_volume *nv = dir->vol;
    if (!NVolCaseSensitive(nv))
        return mref;
    NVolClearCaseSensitive(nv);
    mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    int saved = errno;
    NVolSetCaseSensitive(nv);
    errno = saved;
    return mref;
}

mn_err mn_lookup(mn_volume *vol, uint64_t dir_inode, const char *name, uint64_t *inode_out)
{
    ntfs_inode *dir;
    mn_err err = open_inode(vol, dir_inode, &dir);
    if (err)
        return err;

    ntfschar *uname = NULL;
    int ulen;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        err = MN_ERR_NOT_DIR;
    } else if ((ulen = ntfs_mbstoucs(name, &uname)) < 0) {
        err = MN_ERR_BAD_NAME;
    } else {
        u64 mref = lookup_ci(dir, uname, ulen);
        if (mref == (u64)-1)
            err = map_errno(errno);
        else
            *inode_out = MREF(mref);
    }
    free(uname);
    ntfs_inode_close(dir);
    return err;
}

mn_err mn_resolve(mn_volume *vol, const char *path, uint64_t *inode_out)
{
    if (!path || path[0] != '/')
        return MN_ERR_INVALID;
    char *copy = strdup(path);
    if (!copy)
        return MN_ERR_NOMEM;

    uint64_t cur = FILE_root;
    mn_err err = MN_OK;
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part && !err;
         part = strtok_r(NULL, "/", &save))
        err = mn_lookup(vol, cur, part, &cur);
    free(copy);
    if (!err)
        *inode_out = cur;
    return err;
}

typedef struct {
    mn_readdir_cb cb;
    void *ctx;
    mn_err err;
    bool stopped;
} readdir_state;

static int readdir_filler(void *dirent, const ntfschar *name, const int name_len,
                          const int name_type, const s64 pos, const MFT_REF mref,
                          const unsigned dt_type)
{
    (void)pos;
    readdir_state *st = dirent;

    /* Each file with a short 8.3 alias appears twice; keep only the long name. */
    if (name_type == FILE_NAME_DOS)
        return 0;

    char *utf8 = NULL;
    if (ntfs_ucstombs(name, name_len, &utf8, 0) < 0) {
        st->err = MN_ERR_INVALID;
        return -1;
    }
    int ret = 0;
    if (strcmp(utf8, ".") != 0 && strcmp(utf8, "..") != 0) {
        mn_dirent ent = { .name = utf8, .inode = MREF(mref), .type = type_of_dt(dt_type) };
        if (st->cb(st->ctx, &ent)) {
            st->stopped = true;
            ret = 1;
        }
    }
    free(utf8);
    return ret;
}

mn_err mn_readdir(mn_volume *vol, uint64_t dir_inode, mn_readdir_cb cb, void *ctx)
{
    ntfs_inode *dir;
    mn_err err = open_inode(vol, dir_inode, &dir);
    if (err)
        return err;

    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        ntfs_inode_close(dir);
        return MN_ERR_NOT_DIR;
    }

    readdir_state st = { .cb = cb, .ctx = ctx };
    s64 pos = 0;
    if (ntfs_readdir(dir, &pos, &st, readdir_filler) && !st.stopped && !st.err)
        st.err = map_errno(errno);
    ntfs_inode_close(dir);
    return st.err;
}

mn_err mn_read(mn_volume *vol, uint64_t inode, uint64_t offset,
               void *buf, size_t len, size_t *nread)
{
    *nread = 0;
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;

    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) {
        ntfs_inode_close(ni);
        return MN_ERR_IS_DIR;
    }

    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        err = map_errno(errno);
        ntfs_inode_close(ni);
        return err;
    }

    size_t done = 0;
    while (done < len && (s64)(offset + done) < na->data_size) {
        s64 n = ntfs_attr_pread(na, (s64)(offset + done), (s64)(len - done),
                                (char *)buf + done);
        if (n < 0) {
            err = map_errno(errno);
            break;
        }
        if (n == 0)
            break;
        done += (size_t)n;
    }
    *nread = done;
    ntfs_attr_close(na);
    ntfs_inode_close(ni);
    return err;
}

/* ---- Writing ---- */

static void mark_archive(ntfs_inode *ni)
{
    if (!(ni->flags & FILE_ATTR_ARCHIVE)) {
        ni->flags |= FILE_ATTR_ARCHIVE;
        NInoFileNameSetDirty(ni);
    }
}

/* Convert and validate a new name. On success *uname must be freed. */
static mn_err make_name(mn_volume *vol, const char *name, ntfschar **uname, int *len)
{
    *uname = NULL;
    if (!name || !*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, ".."))
        return MN_ERR_BAD_NAME;
    *len = ntfs_mbstoucs(name, uname);
    if (*len < 0)
        return MN_ERR_BAD_NAME;
    if (*len > NTFS_MAX_NAME_LEN || ntfs_forbidden_names(vol->nv, *uname, *len, TRUE)) {
        free(*uname);
        *uname = NULL;
        return MN_ERR_BAD_NAME;
    }
    return MN_OK;
}

/* Open a directory that new entries may be added to or removed from. */
static mn_err open_dir_for_write(mn_volume *vol, uint64_t dir_inode, ntfs_inode **out)
{
    *out = NULL;
    if (vol->read_only)
        return MN_ERR_READ_ONLY;
    ntfs_inode *dir;
    mn_err err = open_inode(vol, dir_inode, &dir);
    if (err)
        return err;
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY))
        err = MN_ERR_NOT_DIR;
    else if (dir->mft_no == FILE_Extend)
        err = MN_ERR_PERMISSION;
    else if (dir->flags & FILE_ATTR_REPARSE_POINT)
        err = MN_ERR_UNSUPPORTED;     /* junctions, OneDrive placeholders, ... */
    if (err) {
        ntfs_inode_close(dir);
        return err;
    }
    *out = dir;
    return MN_OK;
}

/* Open a user file whose contents may be modified. */
static mn_err open_file_for_write(mn_volume *vol, uint64_t inode,
                                  ntfs_inode **ni_out, ntfs_attr **na_out)
{
    *ni_out = NULL;
    *na_out = NULL;
    if (vol->read_only)
        return MN_ERR_READ_ONLY;
    if (inode < FILE_first_user)
        return MN_ERR_PERMISSION;
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY)
        err = MN_ERR_IS_DIR;
    else if (ni->flags & FILE_ATTR_REPARSE_POINT)
        err = MN_ERR_UNSUPPORTED;
    else if (ni->flags & FILE_ATTR_ENCRYPTED)
        err = MN_ERR_PERMISSION;
    if (!err) {
        *na_out = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (!*na_out)
            err = map_errno(errno);
    }
    if (err) {
        ntfs_inode_close(ni);
        return err;
    }
    *ni_out = ni;
    return MN_OK;
}

/* Close after modifying: compressed attributes need their last block compressed. */
static mn_err close_file_after_write(ntfs_inode *ni, ntfs_attr *na, mn_err err)
{
    if ((na->data_flags & ATTR_COMPRESSION_MASK) && ntfs_attr_pclose(na) && !err)
        err = map_errno(errno);
    ntfs_attr_close(na);
    mark_archive(ni);
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni) && !err)
        err = map_errno(errno);
    return err;
}

mn_err mn_create(mn_volume *vol, uint64_t dir_inode, const char *name,
                 mn_type type, uint64_t *inode_out)
{
    if (type != MN_TYPE_FILE && type != MN_TYPE_DIR)
        return MN_ERR_INVALID;

    ntfs_inode *dir;
    mn_err err = open_dir_for_write(vol, dir_inode, &dir);
    if (err)
        return err;

    ntfschar *uname;
    int ulen;
    err = make_name(vol, name, &uname, &ulen);
    if (!err && lookup_ci(dir, uname, ulen) != (u64)-1)
        err = MN_ERR_EXISTS;   /* also when only the case differs, as on Windows */
    if (err) {
        free(uname);
        ntfs_inode_close(dir);
        return err;
    }

    /* Security id 0: libntfs-3g builds a default descriptor, as ntfs-3g does without user mapping. */
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, (u8)ulen,
                                 type == MN_TYPE_DIR ? S_IFDIR : S_IFREG);
    if (!ni) {
        err = map_errno(errno);
    } else {
        *inode_out = ni->mft_no;
        mark_archive(ni);
        NInoSetDirty(ni);
        /* Closing in the directory keeps the parent's index entry in sync. */
        if (ntfs_inode_close_in_dir(ni, dir))
            err = map_errno(errno);
        ntfs_inode_update_times(dir, NTFS_UPDATE_MCTIME);
    }
    free(uname);
    if (ntfs_inode_close(dir) && !err)
        err = map_errno(errno);
    return err;
}

mn_err mn_write(mn_volume *vol, uint64_t inode, uint64_t offset,
                const void *buf, size_t len)
{
    ntfs_inode *ni;
    ntfs_attr *na;
    mn_err err = open_file_for_write(vol, inode, &ni, &na);
    if (err)
        return err;

    size_t done = 0;
    while (done < len) {
        s64 n = ntfs_attr_pwrite(na, (s64)(offset + done), (s64)(len - done),
                                 (const char *)buf + done);
        if (n <= 0) {
            err = n < 0 ? map_errno(errno) : MN_ERR_IO;
            break;
        }
        done += (size_t)n;
    }
    return close_file_after_write(ni, na, err);
}

mn_err mn_truncate(mn_volume *vol, uint64_t inode, uint64_t size)
{
    ntfs_inode *ni;
    ntfs_attr *na;
    mn_err err = open_file_for_write(vol, inode, &ni, &na);
    if (err)
        return err;

    if ((na->data_flags & ATTR_COMPRESSION_MASK) && (s64)size > na->initialized_size) {
        /* Grow compressed files by writing a final zero, as ntfs-3g does (creates a hole). */
        char zero = 0;
        if (ntfs_attr_pwrite(na, (s64)size - 1, 1, &zero) <= 0)
            err = map_errno(errno);
    } else if (ntfs_attr_truncate(na, (s64)size)) {
        err = map_errno(errno);
    }
    return close_file_after_write(ni, na, err);
}

/* Remove one name of an inode. ntfs_delete() closes both inodes. */
static mn_err unlink_name(mn_volume *vol, ntfs_inode *dir, const ntfschar *uname, int ulen)
{
    u64 mref = ntfs_inode_lookup_by_name(dir, uname, ulen);
    if (mref == (u64)-1) {
        mn_err err = map_errno(errno);
        ntfs_inode_close(dir);
        return err;
    }
    if (MREF(mref) < FILE_first_user) {
        ntfs_inode_close(dir);
        return MN_ERR_PERMISSION;
    }
    ntfs_inode *ni = ntfs_inode_open(vol->nv, MREF(mref));
    if (!ni) {
        mn_err err = map_errno(errno);
        ntfs_inode_close(dir);
        return err;
    }
    if (ntfs_delete(vol->nv, NULL, ni, dir, (ntfschar *)uname, (u8)ulen))
        return map_errno(errno);
    return MN_OK;
}

mn_err mn_remove(mn_volume *vol, uint64_t dir_inode, const char *name)
{
    ntfs_inode *dir;
    mn_err err = open_dir_for_write(vol, dir_inode, &dir);
    if (err)
        return err;

    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs(name, &uname);
    if (ulen < 0) {
        ntfs_inode_close(dir);
        return MN_ERR_BAD_NAME;
    }
    err = unlink_name(vol, dir, uname, ulen);
    free(uname);
    return err;
}

/* Add a name for an existing inode in a directory. */
static mn_err link_name(mn_volume *vol, uint64_t inode, uint64_t dir_inode,
                        const ntfschar *uname, int ulen)
{
    ntfs_inode *dir;
    mn_err err = open_dir_for_write(vol, dir_inode, &dir);
    if (err)
        return err;
    ntfs_inode *ni;
    err = open_inode(vol, inode, &ni);
    if (err) {
        ntfs_inode_close(dir);
        return err;
    }
    if (ntfs_link(ni, dir, (ntfschar *)uname, (u8)ulen)) {
        err = map_errno(errno);
    } else {
        ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
        ntfs_inode_update_times(dir, NTFS_UPDATE_MCTIME);
    }
    /* Close the directory first so ni's file name can be synced against the index. */
    if (ntfs_inode_close(dir) && !err)
        err = map_errno(errno);
    if (ntfs_inode_close(ni) && !err)
        err = map_errno(errno);
    return err;
}

static mn_err unlink_name_in(mn_volume *vol, uint64_t dir_inode, const ntfschar *uname, int ulen)
{
    ntfs_inode *dir;
    mn_err err = open_dir_for_write(vol, dir_inode, &dir);
    if (err)
        return err;
    return unlink_name(vol, dir, uname, ulen);
}

static mn_err lookup_u(mn_volume *vol, uint64_t dir_inode, const ntfschar *uname,
                       int ulen, uint64_t *out)
{
    ntfs_inode *dir;
    mn_err err = open_inode(vol, dir_inode, &dir);
    if (err)
        return err;
    u64 mref = lookup_ci(dir, uname, ulen);
    if (mref == (u64)-1)
        err = map_errno(errno);
    else
        *out = MREF(mref);
    ntfs_inode_close(dir);
    return err;
}

static mn_err is_dir(mn_volume *vol, uint64_t inode, bool *out)
{
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;
    *out = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
    ntfs_inode_close(ni);
    return MN_OK;
}

/* True if `inode` is `dir_inode` or one of its ancestors. */
static mn_err is_ancestor(mn_volume *vol, uint64_t inode, uint64_t dir_inode, bool *out)
{
    *out = false;
    uint64_t cur = dir_inode;
    for (int depth = 0; depth < 4096; depth++) {
        if (cur == inode) {
            *out = true;
            return MN_OK;
        }
        if (cur == FILE_root)
            return MN_OK;
        ntfs_inode *ni;
        mn_err err = open_inode(vol, cur, &ni);
        if (err)
            return err;
        ntfs_inode *parent = ntfs_dir_parent_inode(ni);
        ntfs_inode_close(ni);
        if (!parent)
            return map_errno(errno);
        cur = parent->mft_no;
        ntfs_inode_close(parent);
    }
    return MN_ERR_CORRUPT;  /* parent chain loops */
}

static unsigned rename_seq;

static mn_err make_tmp_name(ntfschar **uname, int *len)
{
    char tmp[96];
    snprintf(tmp, sizeof(tmp), ".macntfs-rename-%d-%u", (int)getpid(), ++rename_seq);
    *len = ntfs_mbstoucs(tmp, uname);
    return *len < 0 ? MN_ERR_NOMEM : MN_OK;
}

mn_err mn_rename(mn_volume *vol, uint64_t src_dir, const char *src_name,
                 uint64_t dst_dir, const char *dst_name)
{
    if (vol->read_only)
        return MN_ERR_READ_ONLY;

    ntfschar *usrc = NULL, *udst = NULL, *utmp = NULL;
    int lsrc, ldst, ltmp = 0;
    uint64_t src_ino, dst_ino;
    bool src_is_dir, dst_exists = false;
    mn_err err;

    lsrc = ntfs_mbstoucs(src_name, &usrc);
    if (lsrc < 0)
        return MN_ERR_BAD_NAME;
    if ((err = make_name(vol, dst_name, &udst, &ldst)))
        goto out;
    if ((err = lookup_u(vol, src_dir, usrc, lsrc, &src_ino)))
        goto out;
    if (src_ino < FILE_first_user) {
        err = MN_ERR_PERMISSION;
        goto out;
    }
    if ((err = is_dir(vol, src_ino, &src_is_dir)))
        goto out;

    if (src_is_dir) {
        bool loop;
        if ((err = is_ancestor(vol, src_ino, dst_dir, &loop)))
            goto out;
        if (loop) {
            err = MN_ERR_INVALID;   /* moving a directory into itself */
            goto out;
        }
    }

    err = lookup_u(vol, dst_dir, udst, ldst, &dst_ino);
    if (err == MN_OK) {
        if (dst_ino == src_ino) {
            /* Identical name, or another hard link to the same file: nothing to do. */
            if (src_dir != dst_dir ||
                (lsrc == ldst && !memcmp(usrc, udst, (size_t)lsrc * sizeof(ntfschar))))
                goto out;
            /*
             * Case-only rename ("a.txt" -> "A.txt"). Directory indexes are
             * case-insensitive, so the new name can't coexist with the old,
             * and removing the only name would delete the file. Hold the
             * inode under a temporary name while swapping.
             */
            if ((err = make_tmp_name(&utmp, &ltmp)))
                goto out;
            if ((err = link_name(vol, src_ino, src_dir, utmp, ltmp)))
                goto out;
            if ((err = unlink_name_in(vol, src_dir, usrc, lsrc)) == MN_OK &&
                (err = link_name(vol, src_ino, dst_dir, udst, ldst)) != MN_OK)
                link_name(vol, src_ino, src_dir, usrc, lsrc);
            unlink_name_in(vol, src_dir, utmp, ltmp);
            goto out;
        } else {
            bool dst_is_dir;
            if ((err = is_dir(vol, dst_ino, &dst_is_dir)))
                goto out;
            if (dst_is_dir != src_is_dir) {
                err = dst_is_dir ? MN_ERR_IS_DIR : MN_ERR_NOT_DIR;
                goto out;
            }
            dst_exists = true;
        }
    } else if (err != MN_ERR_NOT_FOUND) {
        goto out;
    }
    err = MN_OK;

    /*
     * Not atomic: NTFS has no rename primitive in libntfs-3g. Like ntfs-3g,
     * park an existing destination under a temporary name first so it can
     * be restored if linking the source fails.
     */
    if (dst_exists) {
        if ((err = make_tmp_name(&utmp, &ltmp)))
            goto out;
        if (src_is_dir) {
            /* Only an empty directory may be replaced. */
            ntfs_inode *d;
            if ((err = open_inode(vol, dst_ino, &d)))
                goto out;
            int empty = ntfs_check_empty_dir(d);
            ntfs_inode_close(d);
            if (empty < 0) {
                err = map_errno(errno);
                goto out;
            }
        }
        if ((err = link_name(vol, dst_ino, dst_dir, utmp, ltmp)))
            goto out;
        if ((err = unlink_name_in(vol, dst_dir, udst, ldst))) {
            unlink_name_in(vol, dst_dir, utmp, ltmp);
            goto out;
        }
    }

    if ((err = link_name(vol, src_ino, dst_dir, udst, ldst)))
        goto restore;
    if ((err = unlink_name_in(vol, src_dir, usrc, lsrc))) {
        unlink_name_in(vol, dst_dir, udst, ldst);
        goto restore;
    }
    if (dst_exists)
        err = unlink_name_in(vol, dst_dir, utmp, ltmp);  /* frees the replaced item */
    goto out;

restore:
    if (dst_exists && link_name(vol, dst_ino, dst_dir, udst, ldst) == MN_OK)
        unlink_name_in(vol, dst_dir, utmp, ltmp);
out:
    free(usrc);
    free(udst);
    free(utmp);
    return err;
}

mn_err mn_set_times(mn_volume *vol, uint64_t inode, const struct timespec *birth,
                    const struct timespec *mod, const struct timespec *access)
{
    if (vol->read_only)
        return MN_ERR_READ_ONLY;
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;
    if (birth)
        ni->creation_time = timespec2ntfs(*birth);
    if (mod)
        ni->last_data_change_time = timespec2ntfs(*mod);
    if (access)
        ni->last_access_time = timespec2ntfs(*access);
    /* CTIME update also marks the inode and its file names dirty. */
    ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    if (ntfs_inode_close(ni))
        err = map_errno(errno);
    return err;
}

mn_err mn_set_win_attrs(mn_volume *vol, uint64_t inode, uint32_t mask, uint32_t attrs)
{
    const uint32_t settable = MN_WIN_READONLY | MN_WIN_HIDDEN | MN_WIN_SYSTEM | MN_WIN_ARCHIVE;
    if (mask & ~settable)
        return MN_ERR_INVALID;
    if (vol->read_only)
        return MN_ERR_READ_ONLY;
    if (inode < FILE_first_user && inode != FILE_root)
        return MN_ERR_PERMISSION;
    ntfs_inode *ni;
    mn_err err = open_inode(vol, inode, &ni);
    if (err)
        return err;
    uint32_t flags = le32_to_cpu(ni->flags);
    flags = (flags & ~mask) | (attrs & mask);
    ni->flags = cpu_to_le32(flags);
    NInoFileNameSetDirty(ni);
    ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
    if (ntfs_inode_close(ni))
        err = map_errno(errno);
    return err;
}

mn_err mn_sync(mn_volume *vol)
{
    if (vol->read_only)
        return MN_OK;
    struct ntfs_device *dev = vol->nv->dev;
    if (dev->d_ops->sync && dev->d_ops->sync(dev))
        return map_errno(errno);
    return MN_OK;
}
