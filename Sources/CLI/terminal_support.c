#include <locale.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <wchar.h>

static const int watched_signals[] = {SIGINT, SIGTERM, SIGHUP};
static struct sigaction previous[3];
static int installed;
static volatile sig_atomic_t interrupted;

static void on_interrupt(int number) {
    interrupted = number;
}

int proxyctl_terminal_size(unsigned short *columns, unsigned short *rows) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || !size.ws_col || !size.ws_row) {
        return 0;
    }
    *columns = size.ws_col;
    *rows = size.ws_row;
    return 1;
}

void proxyctl_terminal_begin(void) {
    setlocale(LC_CTYPE, "en_US.UTF-8");
    interrupted = 0;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = on_interrupt;
    for (installed = 0; installed < 3; ++installed) {
        if (sigaction(watched_signals[installed], &action, &previous[installed]) != 0) {
            break;
        }
    }
}

void proxyctl_terminal_end(void) {
    while (installed > 0) {
        --installed;
        sigaction(watched_signals[installed], &previous[installed], NULL);
    }
}

int proxyctl_terminal_interrupt(void) { return interrupted; }
int proxyctl_terminal_width(unsigned int scalar) { return wcwidth((wchar_t)scalar); }
