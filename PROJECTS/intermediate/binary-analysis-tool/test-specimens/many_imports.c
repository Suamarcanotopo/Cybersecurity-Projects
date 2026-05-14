// ©AngelaMos | 2026
// many_imports.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>

static volatile int running = 1;

static void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

static void *worker_thread(void *arg) {
    int id = *(int *)arg;
    struct timespec ts = {0, 100000000};

    while (running) {
        double val = sin((double)id * 0.1) * cos((double)id * 0.2);
        printf("Worker %d: computed %.6f\n", id, val);
        nanosleep(&ts, NULL);
    }
    return NULL;
}

static void scan_directory(const char *path) {
    DIR *dir = opendir(path);
    if (!dir) return;

    struct dirent *ent;
    struct stat st;
    char fullpath[4096];

    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;

        snprintf(fullpath, sizeof(fullpath), "%s/%s", path, ent->d_name);

        if (stat(fullpath, &st) == 0) {
            printf("  %c %8ld %s\n",
                   S_ISDIR(st.st_mode) ? 'd' : '-',
                   (long)st.st_size,
                   ent->d_name);
        }
    }
    closedir(dir);
}

static void mmap_self(void) {
    int fd = open("/proc/self/exe", O_RDONLY);
    if (fd < 0) return;

    struct stat st;
    fstat(fd, &st);

    void *map = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map != MAP_FAILED) {
        unsigned char *bytes = (unsigned char *)map;
        printf("Self ELF magic: %02x %02x %02x %02x\n",
               bytes[0], bytes[1], bytes[2], bytes[3]);
        munmap(map, st.st_size);
    }
    close(fd);
}

static void try_dlopen(void) {
    void *handle = dlopen("libm.so.6", RTLD_LAZY);
    if (handle) {
        typedef double (*pow_fn)(double, double);
        pow_fn p = (pow_fn)dlsym(handle, "pow");
        if (p) {
            printf("dlsym(pow): 2^10 = %.0f\n", p(2.0, 10.0));
        }
        dlclose(handle);
    }
}

static void network_check(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(80);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    struct timeval tv = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
}

int main(void) {
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("=== System Probe ===\n");

    mmap_self();
    try_dlopen();
    scan_directory("/tmp");
    network_check();

    int ids[] = {1, 2, 3};
    pthread_t threads[3];
    for (int i = 0; i < 3; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &ids[i]);
    }

    sleep(1);
    running = 0;

    for (int i = 0; i < 3; i++) {
        pthread_join(threads[i], NULL);
    }

    printf("Done.\n");
    return 0;
}
