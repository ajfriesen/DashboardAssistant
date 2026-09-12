/* mkfs.btrfs --rootdir walks the tree with glibc nftw(), whose internal
   stat calls never cross the PLT — fakeroot and stat-family LD_PRELOAD
   shims are blind to them. nftw itself IS a PLT call though, and hands the
   walker's callback a stat buffer we can scrub, so every inode the image
   records is owned by root. */
#define _XOPEN_SOURCE 700
#define _GNU_SOURCE
#include <ftw.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/stat.h>

typedef int (*nftw_cb)(const char *, const struct stat *, int, struct FTW *);
static __thread nftw_cb user_fn;

static int scrub_fn(const char *path, const struct stat *sb, int type, struct FTW *ftwbuf) {
    struct stat s;
    memcpy(&s, sb, sizeof s);
    s.st_uid = 0;
    s.st_gid = 0;
    return user_fn(path, &s, type, ftwbuf);
}

int nftw(const char *dir, nftw_cb fn, int nopenfd, int flags) {
    static int (*real)(const char *, nftw_cb, int, int);
    if (!real) real = dlsym(RTLD_NEXT, "nftw");
    user_fn = fn;
    return real(dir, scrub_fn, nopenfd, flags);
}

/* Belt and braces: the handful of direct stat calls mkfs also makes
   (top-level dir, size accounting) go through these PLT symbols. */
static void scrub(struct stat *st) { if (st) { st->st_uid = 0; st->st_gid = 0; } }
#define WRAP(name, ...) \
    static int (*real_##name)(__VA_ARGS__);
WRAP(lstat, const char *, struct stat *)
int lstat(const char *p, struct stat *st) {
    if (!real_lstat) real_lstat = dlsym(RTLD_NEXT, "lstat");
    int r = real_lstat(p, st); if (!r) scrub(st); return r;
}
WRAP(stat, const char *, struct stat *)
int stat(const char *p, struct stat *st) {
    if (!real_stat) real_stat = dlsym(RTLD_NEXT, "stat");
    int r = real_stat(p, st); if (!r) scrub(st); return r;
}
WRAP(fstat, int, struct stat *)
int fstat(int fd, struct stat *st) {
    if (!real_fstat) real_fstat = dlsym(RTLD_NEXT, "fstat");
    int r = real_fstat(fd, st); if (!r) scrub(st); return r;
}
