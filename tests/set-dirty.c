/* Test helper: set the NTFS volume dirty flag, as Windows does when chkdsk is scheduled. */
#include <stdio.h>
#include <time.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/volume.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <image>\n", argv[0]);
        return 2;
    }
    ntfs_volume *vol = ntfs_mount(argv[1], NTFS_MNT_NONE);
    if (!vol) {
        perror("ntfs_mount");
        return 1;
    }
    int rc = ntfs_volume_write_flags(vol, vol->flags | VOLUME_IS_DIRTY) ? 1 : 0;
    ntfs_umount(vol, FALSE);
    return rc;
}
