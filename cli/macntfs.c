/*
 * macntfs - command-line front end to the MAC_NTFS engine.
 *
 * Usage: macntfs <device-or-image> <command> [args]
 */
#include "mn.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *prog = "macntfs";

static void usage(void)
{
    fprintf(stderr,
        "usage: %s <device-or-image> <command> [args]\n"
        "\n"
        "read commands:\n"
        "  info                 volume label, size, and safety state\n"
        "  ls [-l] [path]       list a directory (default /)\n"
        "  stat <path>          show metadata for one item\n"
        "  cat <path>           write a file's contents to stdout\n"
        "  get <path> <local>   copy a file out to the local filesystem\n"
        "\n"
        "write commands (refused on hibernated / unsafely removed volumes):\n"
        "  put <local> <path>   copy a local file in (replaces an existing file)\n"
        "  mkdir <path>         create a directory\n"
        "  rm <path>            remove a file or empty directory\n"
        "  mv <from> <to>       rename or move\n"
        "  truncate <path> <n>  set a file's size\n"
        "  touch <path>         create an empty file, or update its modified time\n",
        prog);
    exit(2);
}

static int fail(const char *what, mn_err err)
{
    fprintf(stderr, "%s: %s: %s\n", prog, what, mn_strerror(err));
    return 1;
}

static const char *type_name(mn_type t)
{
    switch (t) {
    case MN_TYPE_FILE:    return "file";
    case MN_TYPE_DIR:     return "directory";
    case MN_TYPE_SYMLINK: return "reparse point";
    default:              return "other";
    }
}

static void format_time(struct timespec ts, char *buf, size_t len)
{
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    strftime(buf, len, "%Y-%m-%d %H:%M:%S", &tm);
}

static void format_win_attrs(uint32_t a, char out[9])
{
    snprintf(out, 9, "%c%c%c%c%c%c%c",
             a & MN_WIN_READONLY   ? 'R' : '-',
             a & MN_WIN_HIDDEN     ? 'H' : '-',
             a & MN_WIN_SYSTEM     ? 'S' : '-',
             a & MN_WIN_ARCHIVE    ? 'A' : '-',
             a & MN_WIN_COMPRESSED ? 'C' : '-',
             a & MN_WIN_ENCRYPTED  ? 'E' : '-',
             a & MN_WIN_SPARSE     ? 'P' : '-');
}

/* ---- info ---- */

static int cmd_info(mn_volume *vol)
{
    mn_volume_info info;
    mn_err err = mn_volume_get_info(vol, &info);
    if (err)
        return fail("info", err);

    printf("label:          %s\n", info.label[0] ? info.label : "(none)");
    printf("ntfs version:   %u.%u\n", info.major_ver, info.minor_ver);
    printf("cluster size:   %u\n", info.cluster_size);
    printf("total bytes:    %" PRIu64 "\n", info.total_bytes);
    printf("free bytes:     %" PRIu64 "\n", info.free_bytes);
    printf("opened:         %s\n", info.read_only ? "read-only" : "read-write");
    printf("dirty flag:     %s\n", info.dirty ? "SET" : "clear");
    printf("hibernated:     %s\n", info.hibernated ? "YES" : "no");
    printf("journal:        %s\n", info.unclean_journal ? "UNCLEAN" : "clean");
    bool safe = !info.hibernated && !info.unclean_journal;
    printf("safe to write:  %s\n", safe ? "yes" : "NO");
    return 0;
}

/* ---- ls ---- */

typedef struct {
    mn_volume *vol;
    bool long_format;
    int count;
} ls_ctx;

static int ls_entry(void *p, const mn_dirent *ent)
{
    ls_ctx *ctx = p;
    ctx->count++;
    if (!ctx->long_format) {
        printf("%s%s\n", ent->name, ent->type == MN_TYPE_DIR ? "/" : "");
        return 0;
    }

    mn_attr a;
    if (mn_stat(ctx->vol, ent->inode, &a) != MN_OK) {
        printf("?  %12s  %19s  %s\n", "?", "?", ent->name);
        return 0;
    }
    char when[32], attrs[9];
    format_time(a.mod_time, when, sizeof(when));
    format_win_attrs(a.win_attrs, attrs);
    printf("%c %s %12" PRIu64 "  %s  %s%s\n",
           a.type == MN_TYPE_DIR ? 'd' : a.type == MN_TYPE_SYMLINK ? 'l' : '-',
           attrs, a.size, when, ent->name, a.type == MN_TYPE_DIR ? "/" : "");
    return 0;
}

static int cmd_ls(mn_volume *vol, int argc, char **argv)
{
    ls_ctx ctx = { .vol = vol };
    const char *path = "/";
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-l") == 0)
            ctx.long_format = true;
        else
            path = argv[i];
    }

    uint64_t ino;
    mn_err err = mn_resolve(vol, path, &ino);
    if (err)
        return fail(path, err);
    err = mn_readdir(vol, ino, ls_entry, &ctx);
    if (err)
        return fail(path, err);
    return 0;
}

/* ---- stat ---- */

static int cmd_stat(mn_volume *vol, int argc, char **argv)
{
    if (argc != 1)
        usage();
    uint64_t ino;
    mn_attr a;
    mn_err err = mn_resolve(vol, argv[0], &ino);
    if (!err)
        err = mn_stat(vol, ino, &a);
    if (err)
        return fail(argv[0], err);

    char t[32], attrs[9];
    format_win_attrs(a.win_attrs, attrs);
    printf("path:        %s\n", argv[0]);
    printf("inode:       %" PRIu64 "\n", a.inode);
    printf("type:        %s\n", type_name(a.type));
    printf("size:        %" PRIu64 "\n", a.size);
    printf("allocated:   %" PRIu64 "\n", a.alloc_size);
    printf("links:       %u\n", a.nlink);
    printf("attributes:  %s (0x%04x)\n", attrs, a.win_attrs);
    format_time(a.birth_time, t, sizeof(t));  printf("created:     %s\n", t);
    format_time(a.mod_time, t, sizeof(t));    printf("modified:    %s\n", t);
    format_time(a.change_time, t, sizeof(t)); printf("changed:     %s\n", t);
    format_time(a.access_time, t, sizeof(t)); printf("accessed:    %s\n", t);
    return 0;
}

/* ---- cat / get ---- */

static int copy_out(mn_volume *vol, const char *path, FILE *out)
{
    uint64_t ino;
    mn_err err = mn_resolve(vol, path, &ino);
    if (err)
        return fail(path, err);

    static char buf[1 << 20];
    uint64_t off = 0;
    for (;;) {
        size_t n;
        err = mn_read(vol, ino, off, buf, sizeof(buf), &n);
        if (err)
            return fail(path, err);
        if (n == 0)
            break;
        if (fwrite(buf, 1, n, out) != n) {
            perror(prog);
            return 1;
        }
        off += n;
    }
    return 0;
}

static int cmd_cat(mn_volume *vol, int argc, char **argv)
{
    if (argc != 1)
        usage();
    return copy_out(vol, argv[0], stdout);
}

static int cmd_get(mn_volume *vol, int argc, char **argv)
{
    if (argc != 2)
        usage();
    FILE *out = fopen(argv[1], "wb");
    if (!out) {
        perror(argv[1]);
        return 1;
    }
    int rc = copy_out(vol, argv[0], out);
    if (fclose(out) != 0 && rc == 0) {
        perror(argv[1]);
        rc = 1;
    }
    return rc;
}

/* ---- write commands ---- */

/* Split "/a/b/c" into the parent's inode and "c". name points into path. */
static mn_err resolve_parent(mn_volume *vol, const char *path, uint64_t *parent, const char **name)
{
    const char *slash = strrchr(path, '/');
    if (path[0] != '/' || !slash || !slash[1])
        return MN_ERR_INVALID;
    *name = slash + 1;
    if (slash == path) {
        *parent = MN_ROOT_INODE;
        return MN_OK;
    }
    char *dir = strndup(path, (size_t)(slash - path));
    if (!dir)
        return MN_ERR_NOMEM;
    mn_err err = mn_resolve(vol, dir, parent);
    free(dir);
    return err;
}

static int cmd_put(mn_volume *vol, int argc, char **argv)
{
    if (argc != 2)
        usage();
    const char *local = argv[0], *path = argv[1];
    FILE *in = fopen(local, "rb");
    if (!in) {
        perror(local);
        return 1;
    }

    uint64_t parent, ino;
    const char *name;
    mn_err err = resolve_parent(vol, path, &parent, &name);
    if (!err) {
        err = mn_lookup(vol, parent, name, &ino);
        if (err == MN_ERR_NOT_FOUND)
            err = mn_create(vol, parent, name, MN_TYPE_FILE, &ino);
        else if (!err)
            err = mn_truncate(vol, ino, 0);
    }

    static char buf[1 << 20];
    uint64_t off = 0;
    size_t n;
    while (!err && (n = fread(buf, 1, sizeof(buf), in)) > 0) {
        err = mn_write(vol, ino, off, buf, n);
        off += n;
    }
    if (!err && ferror(in)) {
        perror(local);
        fclose(in);
        return 1;
    }
    fclose(in);
    if (!err)
        err = mn_sync(vol);
    return err ? fail(path, err) : 0;
}

static int cmd_mkdir(mn_volume *vol, int argc, char **argv)
{
    if (argc != 1)
        usage();
    uint64_t parent, ino;
    const char *name;
    mn_err err = resolve_parent(vol, argv[0], &parent, &name);
    if (!err)
        err = mn_create(vol, parent, name, MN_TYPE_DIR, &ino);
    return err ? fail(argv[0], err) : 0;
}

static int cmd_rm(mn_volume *vol, int argc, char **argv)
{
    if (argc != 1)
        usage();
    uint64_t parent;
    const char *name;
    mn_err err = resolve_parent(vol, argv[0], &parent, &name);
    if (!err)
        err = mn_remove(vol, parent, name);
    return err ? fail(argv[0], err) : 0;
}

static int cmd_mv(mn_volume *vol, int argc, char **argv)
{
    if (argc != 2)
        usage();
    uint64_t src_dir, dst_dir;
    const char *src_name, *dst_name;
    mn_err err = resolve_parent(vol, argv[0], &src_dir, &src_name);
    if (!err)
        err = resolve_parent(vol, argv[1], &dst_dir, &dst_name);
    if (!err)
        err = mn_rename(vol, src_dir, src_name, dst_dir, dst_name);
    return err ? fail(argv[0], err) : 0;
}

static int cmd_truncate(mn_volume *vol, int argc, char **argv)
{
    if (argc != 2)
        usage();
    char *end;
    unsigned long long size = strtoull(argv[1], &end, 10);
    if (*end || argv[1][0] == '-')
        usage();
    uint64_t ino;
    mn_err err = mn_resolve(vol, argv[0], &ino);
    if (!err)
        err = mn_truncate(vol, ino, size);
    return err ? fail(argv[0], err) : 0;
}

static int cmd_touch(mn_volume *vol, int argc, char **argv)
{
    if (argc != 1)
        usage();
    uint64_t parent, ino;
    const char *name;
    mn_err err = resolve_parent(vol, argv[0], &parent, &name);
    if (!err) {
        err = mn_lookup(vol, parent, name, &ino);
        if (err == MN_ERR_NOT_FOUND) {
            err = mn_create(vol, parent, name, MN_TYPE_FILE, &ino);
        } else if (!err) {
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            err = mn_set_times(vol, ino, NULL, &now, &now);
        }
    }
    return err ? fail(argv[0], err) : 0;
}

/* ---- main ---- */

typedef struct {
    const char *name;
    bool writes;
    int (*run)(mn_volume *, int, char **);
} command;

static int run_info(mn_volume *vol, int argc, char **argv)
{
    (void)argc; (void)argv;
    return cmd_info(vol);
}

static const command commands[] = {
    { "info", false, run_info },
    { "ls",   false, cmd_ls },
    { "stat", false, cmd_stat },
    { "cat",  false, cmd_cat },
    { "get",  false, cmd_get },
    { "put",      true, cmd_put },
    { "mkdir",    true, cmd_mkdir },
    { "rm",       true, cmd_rm },
    { "mv",       true, cmd_mv },
    { "truncate", true, cmd_truncate },
    { "touch",    true, cmd_touch },
};

int main(int argc, char **argv)
{
    if (argc < 3)
        usage();

    const command *cmd = NULL;
    for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
        if (strcmp(argv[2], commands[i].name) == 0)
            cmd = &commands[i];
    if (!cmd)
        usage();

    mn_volume *vol;
    mn_err err = mn_volume_open(argv[1], cmd->writes ? MN_OPEN_READ_WRITE : MN_OPEN_READ_ONLY, &vol);
    if (err)
        return fail(argv[1], err);

    int rc = cmd->run(vol, argc - 3, argv + 3);

    err = mn_volume_close(vol);
    if (err && rc == 0)
        rc = fail("close", err);
    return rc;
}
