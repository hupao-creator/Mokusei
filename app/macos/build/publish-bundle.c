#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

// Only publication is serialized. Every builder renders/signs/probes its own
// staging tree first. The kernel releases this lock if its owner exits.
int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "Usage: publish-bundle <lock> <staged-app> <app> <staged-zip|-> <zip>\n");
        return 2;
    }
    int lock = open(argv[1], O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock < 0 || flock(lock, LOCK_EX) != 0) {
        perror("Could not lock bundle publication");
        if (lock >= 0) close(lock);
        return 1;
    }
    // Retire the old archive before the app changes. An interrupted publisher
    // may leave no archive, but never a new app paired with the old archive.
    char *previous_archive = NULL;
    if (asprintf(&previous_archive, "%s.previous.zip", argv[2]) < 0) {
        perror("Could not allocate archive backup path");
        close(lock);
        return 1;
    }
    int had_archive = rename(argv[5], previous_archive) == 0;
    if (!had_archive && errno != ENOENT) {
        perror("Could not retire previous archive");
        free(previous_archive);
        close(lock);
        return 1;
    }
    int swapped = renamex_np(argv[2], argv[3], RENAME_SWAP);
    if (swapped != 0 && errno == ENOENT) swapped = renamex_np(argv[2], argv[3], RENAME_EXCL);
    if (swapped != 0) {
        perror("Could not atomically publish bundle");
        if (had_archive && rename(previous_archive, argv[5]) != 0) perror("Could not restore previous archive");
        free(previous_archive);
        close(lock);
        return 1;
    }
    int archived = strcmp(argv[4], "-") == 0 ? 0 : rename(argv[4], argv[5]);
    if (archived != 0) {
        perror("Bundle published but archive publication failed");
        free(previous_archive);
        close(lock);
        return 1;
    }
    if (had_archive) unlink(previous_archive);
    free(previous_archive);
    close(lock);
    return 0;
}
